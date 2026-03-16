# ClawdEx Next Features Design

## Design Principles

1. Reuse the existing strengths. ClawdEx already has a workable pattern for discovery plus hot-refresh in `ClawdEx.Skills.Loader`, `ClawdEx.Skills.Registry`, and `ClawdEx.Skills.Watcher`. The plugin system should extend that pattern for runtime code, not create a parallel discovery model.
2. Make state transitions authoritative. Plugins, delivery queues, and CLI-managed configuration need persistent truth in the database, not only in process memory.
3. Separate control-plane and data-plane work. Registries should coordinate; dedicated supervisors should own external I/O and long-running plugin workers.
4. Support minimal boot profiles. Mix tasks for status/health/configure should not need the full browser/channel/application footprint.

## A. Plugin System

### Goals

- Behaviour-driven runtime plugins.
- Discovery from disk and persistence of enabled/configured state.
- Hot-reload for local/workspace plugins.
- Supervised plugin processes.
- First-class integration with tools, health checks, and CLI commands.

### Proposed Architecture

#### Core components

- `ClawdEx.Plugins.Plugin`
  Core behaviour implemented by each plugin.
- `ClawdEx.Plugins.Manifest`
  Parsed manifest struct loaded from `plugin.exs` or `plugin.json`.
- `ClawdEx.Plugins.Loader`
  Discovery layer, modeled after `Skills.Loader`.
- `ClawdEx.Plugins.Registry`
  GenServer that owns manifest state, enabled/disabled status, and runtime metadata.
- `ClawdEx.Plugins.InstanceSupervisor`
  DynamicSupervisor that starts one child supervisor per active plugin.
- `ClawdEx.Plugins.Watcher`
  Debounced file watcher, modeled after `Skills.Watcher`, only for reloadable sources.
- `ClawdEx.Plugins.Runtime`
  Helper that starts/stops/reloads a specific plugin instance.

#### Discovery order

Use the same precedence model already used by skills:

1. `workspace/plugins`
2. `~/.clawd/plugins`
3. `priv/plugins`

Later entries override earlier ones by plugin id, exactly like skills do by name.

#### Manifest format

Prefer `plugin.exs` because it keeps Elixir-native terms and avoids a second config grammar:

```elixir
%{
  id: "jira",
  module: ClawdEx.Plugins.Jira,
  version: "0.1.0",
  reloadable?: true,
  capabilities: [:tool_provider, :health_check],
  paths: ["lib", "priv"],
  config_schema: %{
    base_url: :string,
    api_token: :secret
  }
}
```

#### Behaviour

```elixir
defmodule ClawdEx.Plugins.Plugin do
  @type extension ::
          {:tool, module()}
          | {:health_check, {atom(), module()}}
          | {:cli_command, {String.t(), module()}}
          | {:prompt_fragment, module()}

  @callback id() :: String.t()
  @callback version() :: String.t()
  @callback manifest() :: map()
  @callback init(config :: map()) :: {:ok, map()} | {:error, term()}
  @callback child_specs(config :: map(), runtime_state :: map()) :: [Supervisor.child_spec()]
  @callback extensions() :: [extension()]
  @callback validate_config(config :: map()) :: :ok | {:error, term()}
  @callback terminate(reason :: term(), runtime_state :: map()) :: :ok

  @optional_callbacks init: 1,
                      child_specs: 2,
                      extensions: 0,
                      validate_config: 1,
                      terminate: 2
end
```

This keeps the plugin boundary narrow:

- `init/1` validates and prepares plugin-local runtime state.
- `child_specs/2` returns supervised children owned by the plugin.
- `extensions/0` lets a plugin contribute tools, health checks, or CLI commands without hard-coding them into the core app.

### Supervision Model

The application tree should add a dedicated plugin section:

```elixir
children = [
  {Registry, keys: :unique, name: ClawdEx.PluginProcessRegistry},
  {DynamicSupervisor, name: ClawdEx.PluginInstanceSupervisor, strategy: :one_for_one},
  ClawdEx.Plugins.Registry,
  ClawdEx.Plugins.Watcher
]
```

Each enabled plugin gets its own supervisor:

```elixir
defmodule ClawdEx.Plugins.Runtime do
  use Supervisor

  def start_link(%{plugin: plugin, config: config} = args) do
    Supervisor.start_link(__MODULE__, args, name: via(plugin.id()))
  end

  @impl true
  def init(%{plugin: plugin, config: config}) do
    {:ok, runtime_state} = plugin.init(config)

    children =
      plugin.child_specs(config, runtime_state)
      |> Enum.map(&Supervisor.child_spec(&1, id: make_ref()))

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp via(id) do
    {:via, Registry, {ClawdEx.PluginProcessRegistry, id}}
  end
end
```

This gives each plugin an isolated restart boundary. A crashing plugin should not take down the core router/task/webhook subsystems.

### Registry Responsibilities

`ClawdEx.Plugins.Registry` should own only control-plane state:

- discovered manifests
- enabled/disabled state
- persisted config
- current checksum/version
- runtime status: `inactive | starting | active | reloading | failed`
- extension indexes for tools/health/CLI

It should not run plugin work itself.

Suggested state shape:

```elixir
%{
  plugins: %{
    "jira" => %{
      manifest: manifest,
      config: %{base_url: "..."},
      checksum: "sha256:...",
      status: :active,
      pid: #PID<...>,
      extensions: [tool: ClawdEx.Plugins.Jira.Tool]
    }
  }
}
```

### Hot-Reload

Hot-reload should only apply to workspace/managed plugins marked `reloadable?: true`.

Reload algorithm:

1. `Watcher` receives a file event and debounces it.
2. `Loader` rescans manifests and computes `added`, `changed`, and `removed` by plugin id plus checksum.
3. For `changed`:
   1. validate the new manifest and config
   2. compile/reload code first
   3. stop the old plugin supervisor
   4. purge old modules with `:code.soft_purge/1` and `:code.delete/1`
   5. start a new plugin runtime supervisor
   6. update extension indexes atomically in the registry
4. If compilation or boot fails, keep the previous plugin instance active and mark the candidate failure in plugin metadata.

Sketch:

```elixir
def handle_info(:refresh_plugins, state) do
  {next_manifests, diff} = ClawdEx.Plugins.Loader.refresh(state.plugins)

  new_state =
    Enum.reduce(diff.changed, state, fn {id, candidate}, acc ->
      case reload_plugin(id, candidate, acc) do
        {:ok, acc} -> acc
        {:error, reason, acc} -> put_in(acc, [:plugins, id, :last_error], inspect(reason))
      end
    end)

  {:noreply, new_state}
end
```

### Integrating Plugin Extensions

#### Tools

Move `ClawdEx.Tools.Registry` from a fixed compile-time map to core plus plugin providers:

```elixir
def list_tools(opts \\ []) do
  core_specs()
  |> Kernel.++(ClawdEx.Plugins.Registry.tool_specs())
  |> filter_specs(opts)
end
```

#### Health checks

Define a behaviour:

```elixir
defmodule ClawdEx.Health.Check do
  @callback id() :: atom()
  @callback run(keyword()) :: %{status: :ok | :warning | :error, message: String.t(), details: map()}
end
```

Then let plugins contribute `{ :health_check, {id, module} }`.

#### CLI commands

Plugins can expose Mix-task-adjacent commands without writing directly into core routers:

```elixir
{:cli_command, {"plugin.sync", ClawdEx.Plugins.Jira.MixCommand}}
```

### Plugin Persistence

Persist plugin state so enable/disable/config survives restarts and so reload failures are inspectable.

#### Migration 1: `plugins`

```elixir
defmodule ClawdEx.Repo.Migrations.CreatePlugins do
  use Ecto.Migration

  def change do
    create table(:plugins) do
      add :slug, :string, null: false
      add :module, :string, null: false
      add :version, :string, null: false
      add :source, :string, null: false
      add :path, :string, null: false
      add :checksum, :string, null: false
      add :enabled, :boolean, null: false, default: true
      add :status, :string, null: false, default: "inactive"
      add :manifest, :map, null: false, default: %{}
      add :config, :map, null: false, default: %{}
      add :last_loaded_at, :utc_datetime_usec
      add :last_error, :text

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:plugins, [:slug])
    create index(:plugins, [:enabled, :status])
  end
end
```

#### Migration 2: `plugin_events`

```elixir
defmodule ClawdEx.Repo.Migrations.CreatePluginEvents do
  use Ecto.Migration

  def change do
    create table(:plugin_events) do
      add :plugin_id, references(:plugins, on_delete: :delete_all), null: false
      add :event, :string, null: false
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:plugin_events, [:plugin_id, :inserted_at])
    create index(:plugin_events, [:event])
  end
end
```

`plugin_events` is important for reload/crash auditing; it also gives `mix clawd.status` a safe way to report recent plugin failures.

### Recommended Rollout

1. Implement manifest loading and registry persistence first.
2. Add per-plugin supervisors next.
3. Convert tools/health/CLI discovery to query plugin extensions.
4. Enable hot-reload only for workspace/managed plugins.
5. Add plugin commands such as `mix clawd.plugin.list`, `mix clawd.plugin.enable`, and `mix clawd.plugin.reload`.

## B. CLI Commands via Mix Tasks

### Goals

- Replace the current ad hoc escript-only entry points with first-class Mix tasks.
- Share one domain layer between Mix tasks and the existing `ClawdEx.CLI.*` modules.
- Support minimal boot profiles for `status`, `health`, and `configure`.
- Persist configuration in a structured store, not only `.env`.

### Proposed Command Set

#### `mix clawd.status`

Purpose:

- runtime status
- node/supervisor status
- repo connectivity
- task/webhook/plugin counts
- optional JSON output

Examples:

```bash
mix clawd.status
mix clawd.status --json --verbose
```

#### `mix clawd.health`

Purpose:

- run health checks from core plus plugins
- optional strict exit code
- optionally persist check snapshots

Examples:

```bash
mix clawd.health
mix clawd.health --json --strict
mix clawd.health --check database,plugins,queues
```

#### `mix clawd.configure`

Purpose:

- interactive wizard
- `get/set/unset/list`
- validate configuration before restart
- optional secret-aware storage

Examples:

```bash
mix clawd.configure wizard
mix clawd.configure set ai.openai.api_key sk-...
mix clawd.configure get ai.openai.api_key
mix clawd.configure validate
```

### Shared Domain Layer

Do not put business logic directly in Mix tasks. Add shared modules:

- `ClawdEx.CLI.StatusService`
- `ClawdEx.CLI.HealthService`
- `ClawdEx.Config`
- `ClawdEx.Config.Store`
- `ClawdEx.CLI.Renderer`
- `ClawdEx.CLI.BootProfile`

This lets the existing `ClawdEx.CLI.Status`, `Health`, and `Configure` wrappers call the same services, instead of duplicating logic.

### Boot Profiles

The current application starts browser, channels, watchers, and other long-lived runtime pieces unconditionally. For Mix tasks, that is the wrong boot shape.

Introduce boot profiles:

```elixir
defmodule ClawdEx.CLI.BootProfile do
  def ensure_started(:status) do
    Application.put_env(:clawd_ex, :boot_profile, :status)
    Application.ensure_all_started(:clawd_ex)
  end

  def ensure_started(:health) do
    Application.put_env(:clawd_ex, :boot_profile, :health)
    Application.ensure_all_started(:clawd_ex)
  end

  def ensure_started(:configure) do
    Application.put_env(:clawd_ex, :boot_profile, :configure)
    Application.ensure_all_started(:clawd_ex)
  end
end
```

Then make `ClawdEx.Application.start/2` profile-aware:

```elixir
def start(_type, _args) do
  children =
    base_children() ++
      case Application.get_env(:clawd_ex, :boot_profile, :full) do
        :configure -> [ClawdEx.Repo]
        :status -> [ClawdEx.Repo, ClawdEx.Plugins.Registry]
        :health -> [ClawdEx.Repo, ClawdEx.Plugins.Registry, ClawdEx.Webhooks.Manager]
        :full -> full_runtime_children()
      end

  Supervisor.start_link(children, strategy: :one_for_one, name: ClawdEx.Supervisor)
end
```

That change is also useful outside CLI work because it forces application startup boundaries to become explicit.

### Mix Task Snippets

#### `mix clawd.status`

```elixir
defmodule Mix.Tasks.Clawd.Status do
  use Mix.Task

  @shortdoc "Shows ClawdEx runtime status"

  def run(args) do
    Mix.Task.run("app.config")
    ClawdEx.CLI.BootProfile.ensure_started(:status)

    {opts, _, _} =
      OptionParser.parse(args,
        switches: [json: :boolean, verbose: :boolean]
      )

    snapshot = ClawdEx.CLI.StatusService.snapshot(verbose?: opts[:verbose] || false)
    ClawdEx.CLI.Renderer.render(snapshot, json?: opts[:json] || false)
  end
end
```

Suggested status payload:

```elixir
%{
  node: node(),
  repo: %{connected: true, latency_ms: 4},
  tasks: %{pending: 3, assigned: 1, running: 2},
  webhooks: %{failed_due: 4},
  plugins: %{active: 5, failed: 1},
  supervisors: %{agent_loops: 8, mailboxes: 2},
  memory: %{total_mb: 182.4}
}
```

#### `mix clawd.health`

```elixir
defmodule Mix.Tasks.Clawd.Health do
  use Mix.Task

  @shortdoc "Runs ClawdEx health checks"

  def run(args) do
    Mix.Task.run("app.config")
    ClawdEx.CLI.BootProfile.ensure_started(:health)

    {opts, _, _} =
      OptionParser.parse(args,
        switches: [json: :boolean, strict: :boolean, record: :boolean]
      )

    result = ClawdEx.CLI.HealthService.run(record?: opts[:record] || false)
    ClawdEx.CLI.Renderer.render(result, json?: opts[:json] || false)

    if opts[:strict] && !result.healthy, do: Mix.raise("health checks failed")
  end
end
```

`HealthService.run/1` should combine:

- core checks
- plugin checks from `ClawdEx.Plugins.Registry.health_checks/0`
- queue checks for tasks/A2A/webhooks

#### `mix clawd.configure`

```elixir
defmodule Mix.Tasks.Clawd.Configure do
  use Mix.Task

  @shortdoc "Reads and writes ClawdEx configuration"

  def run(["set", key, value]) do
    Mix.Task.run("app.config")
    ClawdEx.CLI.BootProfile.ensure_started(:configure)
    :ok = ClawdEx.Config.put(key, value, source: :cli)
    Mix.shell().info("updated #{key}")
  end

  def run(["get", key]) do
    Mix.Task.run("app.config")
    ClawdEx.CLI.BootProfile.ensure_started(:configure)
    Mix.shell().info(inspect(ClawdEx.Config.get(key)))
  end

  def run(["wizard"]) do
    Mix.Task.run("app.config")
    ClawdEx.CLI.BootProfile.ensure_started(:configure)
    ClawdEx.CLI.ConfigureWizard.run()
  end

  def run(["validate"]) do
    Mix.Task.run("app.config")
    ClawdEx.CLI.BootProfile.ensure_started(:configure)
    case ClawdEx.Config.validate() do
      :ok -> Mix.shell().info("configuration valid")
      {:error, issues} -> Mix.raise("invalid configuration: #{inspect(issues)}")
    end
  end
end
```

### Configuration Storage

The current `.env`-only approach is acceptable for local development, but it is weak for multi-node runtime control, auditability, and secret rotation. Add a config store with DB persistence and optional environment export.

#### Config API

```elixir
defmodule ClawdEx.Config do
  alias ClawdEx.Config.Store

  def get(key), do: Store.get(key)
  def put(key, value, opts \\ []), do: Store.put(key, value, opts)
  def unset(key), do: Store.unset(key)
  def list(prefix \\ nil), do: Store.list(prefix)
  def validate, do: Store.validate()
end
```

#### Migration 1: `system_settings`

```elixir
defmodule ClawdEx.Repo.Migrations.CreateSystemSettings do
  use Ecto.Migration

  def change do
    create table(:system_settings) do
      add :key, :string, null: false
      add :value, :map, null: false, default: %{}
      add :value_type, :string, null: false
      add :scope, :string, null: false, default: "global"
      add :encrypted, :boolean, null: false, default: false
      add :source, :string, null: false, default: "cli"
      add :updated_by, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:system_settings, [:scope, :key])
    create index(:system_settings, [:encrypted])
  end
end
```

Recommended encoding:

- `value_type = "string" | "integer" | "boolean" | "json" | "secret"`
- `value` always stored as a normalized map, for example `%{"raw" => "4000"}` or `%{"json" => %{...}}`

#### Migration 2: `health_check_runs`

```elixir
defmodule ClawdEx.Repo.Migrations.CreateHealthCheckRuns do
  use Ecto.Migration

  def change do
    create table(:health_check_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :node, :string, null: false
      add :profile, :string, null: false
      add :healthy, :boolean, null: false
      add :duration_ms, :integer, null: false
      add :checks, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:health_check_runs, [:healthy, :inserted_at])
    create index(:health_check_runs, [:node, :inserted_at])
  end
end
```

This table is optional for the first cut, but it is useful if `mix clawd.health --record` becomes part of operations.

### Recommended Rollout

1. Extract shared CLI service modules from the current `ClawdEx.CLI.*` implementations.
2. Add boot profiles to `ClawdEx.Application`.
3. Introduce `system_settings`.
4. Add `mix clawd.status`, `mix clawd.health`, and `mix clawd.configure`.
5. Extend health/status to include plugin runtime summaries.

## Suggested Implementation Order Across Both Features

1. Make application boot profiles explicit.
2. Add persistent configuration storage.
3. Build the plugin registry and instance supervisor.
4. Migrate tool/health/CLI discovery to plugin-provided extensions.
5. Add hot-reload for workspace plugins only.
6. Add operational Mix tasks for plugin management and system status.
