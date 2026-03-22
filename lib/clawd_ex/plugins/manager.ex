defmodule ClawdEx.Plugins.Manager do
  @moduledoc """
  Plugin Manager — GenServer for plugin lifecycle management.

  Loads plugins from two sources:
  1. Application config (compile-time Elixir plugins, backwards compatible)
  2. ~/.clawd/plugins/registry.json (runtime-installed plugins)

  Supports two plugin runtimes:
  - `:beam` — native Elixir modules, loaded via :code.add_pathz + Code.ensure_loaded
  - `:node` — Node.js plugins, bridged via ClawdEx.Plugins.NodeBridge

  Aggregates tools, channels, and providers from all enabled plugins
  and registers them with the respective registries.
  """
  use GenServer

  require Logger

  alias ClawdEx.Plugins.{Plugin, Store}

  # ============================================================================
  # Client API
  # ============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "List all loaded plugins"
  @spec list_plugins() :: [Plugin.t()]
  def list_plugins do
    GenServer.call(__MODULE__, :list_plugins)
  catch
    :exit, _ -> []
  end

  @doc "Get a plugin by id"
  @spec get_plugin(String.t()) :: Plugin.t() | nil
  def get_plugin(id) do
    GenServer.call(__MODULE__, {:get_plugin, id})
  catch
    :exit, _ -> nil
  end

  @doc "Enable a plugin by id"
  @spec enable_plugin(String.t()) :: :ok | {:error, :not_found}
  def enable_plugin(id) do
    GenServer.call(__MODULE__, {:enable_plugin, id})
  end

  @doc "Disable a plugin by id"
  @spec disable_plugin(String.t()) :: :ok | {:error, :not_found}
  def disable_plugin(id) do
    GenServer.call(__MODULE__, {:disable_plugin, id})
  end

  @doc "Get all tools from enabled plugins"
  @spec get_tools() :: [module()]
  def get_tools do
    GenServer.call(__MODULE__, :get_tools)
  catch
    :exit, _ -> []
  end

  @doc "Get all tool specs from enabled plugins (for Node.js plugins)"
  @spec get_tool_specs() :: [map()]
  def get_tool_specs do
    GenServer.call(__MODULE__, :get_tool_specs)
  catch
    :exit, _ -> []
  end

  @doc "Get all providers from enabled plugins"
  @spec get_providers() :: [map()]
  def get_providers do
    GenServer.call(__MODULE__, :get_providers)
  catch
    :exit, _ -> []
  end

  @doc "Get all channels from enabled plugins"
  @spec get_channels() :: [map()]
  def get_channels do
    GenServer.call(__MODULE__, :get_channels)
  catch
    :exit, _ -> []
  end

  @doc "Execute a tool call on a plugin"
  @spec call_tool(String.t(), String.t(), map(), map()) :: {:ok, any()} | {:error, term()}
  def call_tool(plugin_id, tool_name, params, context) do
    GenServer.call(__MODULE__, {:call_tool, plugin_id, tool_name, params, context}, 120_000)
  end

  @doc "Reload all plugins"
  @spec reload() :: :ok
  def reload do
    GenServer.call(__MODULE__, :reload)
  end

  @doc "Install a plugin from a source (npm package, git url, or local path)"
  @spec install(String.t(), keyword()) :: {:ok, Plugin.t()} | {:error, term()}
  def install(source, opts \\ []) do
    GenServer.call(__MODULE__, {:install, source, opts}, 120_000)
  end

  @doc "Uninstall a plugin"
  @spec uninstall(String.t()) :: :ok | {:error, term()}
  def uninstall(plugin_id) do
    GenServer.call(__MODULE__, {:uninstall, plugin_id})
  end

  # ============================================================================
  # Server
  # ============================================================================

  @impl true
  def init(_opts) do
    state = %{
      plugins: %{},
      plugin_states: %{},
      tool_index: %{},
      registry: nil
    }

    state = load_all_plugins(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:list_plugins, _from, state) do
    plugins = state.plugins |> Map.values() |> Enum.sort_by(& &1.id)
    {:reply, plugins, state}
  end

  @impl true
  def handle_call({:get_plugin, id}, _from, state) do
    {:reply, Map.get(state.plugins, id), state}
  end

  @impl true
  def handle_call({:enable_plugin, id}, _from, state) do
    case Map.get(state.plugins, id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      plugin ->
        updated = %{plugin | enabled: true, status: :loaded}
        state = put_in(state.plugins[id], updated)
        persist_enabled_state(state, id, true)
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:disable_plugin, id}, _from, state) do
    case Map.get(state.plugins, id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      plugin ->
        updated = %{plugin | enabled: false, status: :disabled}
        state = put_in(state.plugins[id], updated)
        persist_enabled_state(state, id, false)
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call(:get_tools, _from, state) do
    tools = collect_beam_tool_modules(state)
    {:reply, tools, state}
  end

  @impl true
  def handle_call(:get_tool_specs, _from, state) do
    specs = collect_all_tool_specs(state)
    {:reply, specs, state}
  end

  @impl true
  def handle_call(:get_providers, _from, state) do
    providers = collect_providers(state)
    {:reply, providers, state}
  end

  @impl true
  def handle_call(:get_channels, _from, state) do
    channels = collect_channels(state)
    {:reply, channels, state}
  end

  @impl true
  def handle_call({:call_tool, plugin_id, tool_name, params, context}, _from, state) do
    result =
      case Map.get(state.plugins, plugin_id) do
        nil ->
          {:error, :plugin_not_found}

        %{enabled: false} ->
          {:error, :plugin_disabled}

        %{plugin_type: :beam, module: module} when not is_nil(module) ->
          if function_exported?(module, :handle_tool_call, 3) do
            try do
              module.handle_tool_call(tool_name, params, context)
            rescue
              e -> {:error, {:execution_error, Exception.message(e)}}
            end
          else
            {:error, :tool_call_not_supported}
          end

        %{plugin_type: :node, id: id} ->
          try do
            ClawdEx.Plugins.NodeBridge.call_tool(id, tool_name, params, context)
          rescue
            e -> {:error, {:bridge_error, Exception.message(e)}}
          catch
            :exit, _ -> {:error, :bridge_unavailable}
          end

        _ ->
          {:error, :invalid_plugin_state}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call(:reload, _from, _state) do
    state = load_all_plugins(%{
      plugins: %{},
      plugin_states: %{},
      tool_index: %{},
      registry: nil
    })

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:install, source, opts}, _from, state) do
    case do_install(source, opts) do
      {:ok, plugin} ->
        state = put_in(state.plugins[plugin.id], plugin)
        register_plugin_channels(plugin)
        {:reply, {:ok, plugin}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:uninstall, plugin_id}, _from, state) do
    case Map.get(state.plugins, plugin_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      plugin ->
        # Stop the plugin if it's running
        stop_plugin(plugin, Map.get(state.plugin_states, plugin_id))

        # Unregister channels
        unregister_plugin_channels(plugin)

        # Remove from registry
        case Store.load() do
          {:ok, registry} ->
            registry = Store.remove_plugin(registry, plugin_id)
            Store.save(registry)

          _ ->
            :ok
        end

        # Remove from state
        state = %{
          state
          | plugins: Map.delete(state.plugins, plugin_id),
            plugin_states: Map.delete(state.plugin_states, plugin_id)
        }

        {:reply, :ok, state}
    end
  end

  # ============================================================================
  # Private — Loading
  # ============================================================================

  defp load_all_plugins(state) do
    state
    |> load_config_plugins()
    |> load_registry_plugins()
    |> register_all_channels()
  end

  # Load plugins from Application config (backwards compatible)
  defp load_config_plugins(state) do
    plugin_configs = Application.get_env(:clawd_ex, :plugins, [])

    Enum.reduce(plugin_configs, state, fn plugin_spec, acc ->
      {module, config} = normalize_plugin_spec(plugin_spec)
      load_beam_plugin(acc, module, config)
    end)
  end

  # Load plugins from ~/.clawd/plugins/registry.json
  defp load_registry_plugins(state) do
    case Store.load() do
      {:ok, registry} ->
        state = %{state | registry: registry}

        registry.plugins
        |> Map.values()
        |> Enum.filter(& &1.enabled)
        |> Enum.reduce(state, fn entry, acc ->
          case entry.runtime do
            "beam" -> load_beam_plugin_from_registry(acc, entry)
            "node" -> load_node_plugin_from_registry(acc, entry)
            _ ->
              Logger.warning("Unknown plugin runtime: #{entry.runtime} for #{entry.id}")
              acc
          end
        end)

      {:error, reason} ->
        Logger.warning("Failed to load plugin registry: #{inspect(reason)}")
        state
    end
  end

  defp load_beam_plugin(state, module, config) do
    try do
      id = if function_exported?(module, :id, 0), do: module.id(), else: module.name()
      name = module.name()
      version = module.version()
      description = module.description()

      capabilities =
        if function_exported?(module, :capabilities, 0),
          do: module.capabilities(),
          else: infer_capabilities(module)

      case module.init(config) do
        {:ok, plugin_state} ->
          plugin = %Plugin{
            id: id,
            name: name,
            version: version,
            description: description,
            plugin_type: :beam,
            module: module,
            enabled: true,
            config: config,
            capabilities: capabilities,
            status: :loaded
          }

          Logger.info("Plugin loaded (beam): #{id} v#{version}")

          %{
            state
            | plugins: Map.put(state.plugins, id, plugin),
              plugin_states: Map.put(state.plugin_states, id, plugin_state)
          }

        {:error, reason} ->
          Logger.error("Plugin #{module} init failed: #{inspect(reason)}")
          state
      end
    rescue
      e ->
        Logger.error("Plugin #{module} load failed: #{inspect(e)}")
        state
    end
  end

  defp load_beam_plugin_from_registry(state, entry) do
    beams_dir = Path.join(entry.path, "beams")

    if File.dir?(beams_dir) do
      # Add beam files to code path
      charlist_path = String.to_charlist(beams_dir)
      :code.add_pathz(charlist_path)

      # Load the entry module
      module = String.to_atom(entry.entry)

      case Code.ensure_loaded(module) do
        {:module, ^module} ->
          load_beam_plugin(state, module, entry.config)

        {:error, reason} ->
          Logger.error("Failed to load beam plugin #{entry.id}: #{inspect(reason)}")
          add_error_plugin(state, entry, "Failed to load module: #{inspect(reason)}")
      end
    else
      Logger.warning("Beam plugin #{entry.id} has no beams/ directory at #{entry.path}")
      add_error_plugin(state, entry, "No beams/ directory found")
    end
  end

  defp load_node_plugin_from_registry(state, entry) do
    plugin_dir = Path.expand(entry.path)

    unless File.dir?(plugin_dir) do
      Logger.warning("Node plugin directory not found: #{plugin_dir}")
      add_error_plugin(state, entry, "Plugin directory not found")
    else
      # Read plugin metadata for tools/channels info
      tools =
        case entry.provides do
          %{"tools" => t} when is_list(t) -> t
          %{tools: t} when is_list(t) -> t
          _ -> []
        end

      channels =
        case entry.provides do
          %{"channels" => c} when is_list(c) -> c
          %{channels: c} when is_list(c) -> c
          _ -> []
        end

      capabilities =
        (if tools != [], do: [:tools], else: []) ++
          (if channels != [], do: [:channels], else: [])

      plugin = %Plugin{
        id: entry.id,
        name: entry.name,
        version: entry.version,
        description: entry.description,
        plugin_type: :node,
        module: nil,
        enabled: true,
        config: entry.config,
        path: plugin_dir,
        capabilities: capabilities,
        status: :loaded
      }

      Logger.info("Plugin registered (node): #{entry.id} v#{entry.version}")

      %{state | plugins: Map.put(state.plugins, entry.id, plugin)}
    end
  end

  defp add_error_plugin(state, entry, error_msg) do
    plugin = %Plugin{
      id: entry.id,
      name: entry.name,
      version: entry.version,
      description: entry.description,
      plugin_type: String.to_atom(entry.runtime),
      enabled: false,
      status: :error,
      error: error_msg
    }

    %{state | plugins: Map.put(state.plugins, entry.id, plugin)}
  end

  # ============================================================================
  # Private — Channel registration
  # ============================================================================

  defp register_all_channels(state) do
    # Register builtin channels
    register_builtin_channels()

    # Register plugin channels
    state.plugins
    |> Map.values()
    |> Enum.filter(&(&1.enabled && :channels in &1.capabilities))
    |> Enum.each(&register_plugin_channels/1)

    state
  end

  defp register_builtin_channels do
    # Register Telegram if running
    if Process.whereis(ClawdEx.Channels.Telegram) do
      ClawdEx.Channels.Registry.register("telegram", ClawdEx.Channels.Telegram,
        label: "Telegram",
        source: :builtin
      )
    end

    # Register Discord if running
    if Process.whereis(ClawdEx.Channels.Discord) do
      ClawdEx.Channels.Registry.register("discord", ClawdEx.Channels.Discord,
        label: "Discord",
        source: :builtin
      )
    end
  end

  defp register_plugin_channels(%Plugin{plugin_type: :beam, module: module, id: plugin_id})
       when not is_nil(module) do
    if function_exported?(module, :channels, 0) do
      try do
        module.channels()
        |> Enum.each(fn channel_spec ->
          channel_id = Map.get(channel_spec, :id)
          channel_module = Map.get(channel_spec, :module)
          label = Map.get(channel_spec, :label, channel_id)

          if channel_id && channel_module do
            ClawdEx.Channels.Registry.register(channel_id, channel_module,
              label: label,
              source: :plugin,
              plugin_id: plugin_id
            )
          end
        end)
      rescue
        e ->
          Logger.warning("Failed to register channels for plugin #{plugin_id}: #{inspect(e)}")
      end
    end
  end

  defp register_plugin_channels(%Plugin{plugin_type: :node, id: plugin_id} = plugin) do
    # For Node plugins, register a proxy channel module
    # The actual channel handling goes through NodeBridge
    channels =
      case plugin.config do
        %{"channels" => c} when is_list(c) -> c
        _ -> []
      end

    Enum.each(channels, fn channel_id ->
      ClawdEx.Channels.Registry.register(channel_id, ClawdEx.Plugins.NodeChannelProxy,
        label: channel_id,
        source: :plugin,
        plugin_id: plugin_id
      )
    end)
  end

  defp register_plugin_channels(_), do: :ok

  defp unregister_plugin_channels(%Plugin{plugin_type: :beam, module: module})
       when not is_nil(module) do
    if function_exported?(module, :channels, 0) do
      try do
        module.channels()
        |> Enum.each(fn channel_spec ->
          channel_id = Map.get(channel_spec, :id)
          if channel_id, do: ClawdEx.Channels.Registry.unregister(channel_id)
        end)
      rescue
        _ -> :ok
      end
    end
  end

  defp unregister_plugin_channels(_), do: :ok

  # ============================================================================
  # Private — Collecting tools/providers/channels
  # ============================================================================

  defp collect_beam_tool_modules(state) do
    state.plugins
    |> Map.values()
    |> Enum.filter(&(&1.enabled && &1.plugin_type == :beam && :tools in &1.capabilities))
    |> Enum.flat_map(fn plugin ->
      if plugin.module && function_exported?(plugin.module, :tools, 0) do
        try do
          plugin.module.tools()
        rescue
          e ->
            Logger.warning("Plugin #{plugin.id} tools() failed: #{inspect(e)}")
            []
        end
      else
        []
      end
    end)
  end

  defp collect_all_tool_specs(state) do
    # Beam plugin tools
    beam_specs =
      state.plugins
      |> Map.values()
      |> Enum.filter(&(&1.enabled && &1.plugin_type == :beam && :tools in &1.capabilities))
      |> Enum.flat_map(fn plugin ->
        if plugin.module && function_exported?(plugin.module, :tools, 0) do
          try do
            plugin.module.tools()
            |> Enum.map(fn mod ->
              %{
                name: mod.name(),
                description: mod.description(),
                parameters: mod.parameters(),
                plugin_id: plugin.id,
                plugin_type: :beam
              }
            end)
          rescue
            _ -> []
          end
        else
          []
        end
      end)

    # Node plugin tools — fetched from NodeBridge
    node_specs =
      state.plugins
      |> Map.values()
      |> Enum.filter(&(&1.enabled && &1.plugin_type == :node && :tools in &1.capabilities))
      |> Enum.flat_map(fn plugin ->
        try do
          ClawdEx.Plugins.NodeBridge.list_tools(plugin.id)
          |> Enum.map(&Map.put(&1, :plugin_id, plugin.id))
          |> Enum.map(&Map.put(&1, :plugin_type, :node))
        rescue
          _ -> []
        catch
          :exit, _ -> []
        end
      end)

    beam_specs ++ node_specs
  end

  defp collect_providers(state) do
    state.plugins
    |> Map.values()
    |> Enum.filter(&(&1.enabled && :providers in &1.capabilities))
    |> Enum.flat_map(fn plugin ->
      if plugin.module && function_exported?(plugin.module, :providers, 0) do
        try do
          plugin.module.providers()
        rescue
          _ -> []
        end
      else
        []
      end
    end)
  end

  defp collect_channels(state) do
    state.plugins
    |> Map.values()
    |> Enum.filter(&(&1.enabled && :channels in &1.capabilities))
    |> Enum.flat_map(fn plugin ->
      cond do
        plugin.plugin_type == :beam && plugin.module &&
            function_exported?(plugin.module, :channels, 0) ->
          try do
            plugin.module.channels()
          rescue
            _ -> []
          end

        plugin.plugin_type == :node ->
          # Return channel ids from plugin config
          case plugin.config do
            %{"channels" => c} when is_list(c) ->
              Enum.map(c, fn id -> %{id: id, plugin_id: plugin.id} end)

            _ ->
              []
          end

        true ->
          []
      end
    end)
  end

  # ============================================================================
  # Private — Installation
  # ============================================================================

  defp do_install(source, opts) do
    plugins_dir = Store.plugins_dir()
    File.mkdir_p!(plugins_dir)

    cond do
      # npm package
      String.starts_with?(source, "@") or
          (not String.contains?(source, "/") and not String.contains?(source, ".")) ->
        install_npm_plugin(source, plugins_dir, opts)

      # Local directory
      File.dir?(source) ->
        install_local_plugin(source, plugins_dir, opts)

      # Git URL
      String.starts_with?(source, "http") ->
        install_git_plugin(source, plugins_dir, opts)

      true ->
        {:error, {:invalid_source, source}}
    end
  end

  defp install_npm_plugin(package, plugins_dir, _opts) do
    # Derive plugin id from package name
    plugin_id =
      package
      |> String.replace(~r/^@[^\/]+\//, "")
      |> String.replace(~r/-openclaw-plugin$/, "")
      |> String.replace(~r/-plugin$/, "")

    plugin_dir = Path.join(plugins_dir, plugin_id)
    File.mkdir_p!(plugin_dir)

    Logger.info("Installing npm plugin: #{package} → #{plugin_dir}")

    case System.cmd("npm", ["install", "--prefix", plugin_dir, package],
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        # Find the actual package directory
        package_dir =
          Path.join([plugin_dir, "node_modules", package])

        finalize_install(plugin_id, package_dir, plugin_dir)

      {output, code} ->
        Logger.error("npm install failed (exit #{code}): #{output}")
        # Clean up
        File.rm_rf!(plugin_dir)
        {:error, {:npm_install_failed, output}}
    end
  end

  defp install_local_plugin(source_dir, plugins_dir, _opts) do
    source_dir = Path.expand(source_dir)

    case Store.read_plugin_json(source_dir) do
      {:ok, meta} ->
        plugin_id = meta.id
        plugin_dir = Path.join(plugins_dir, plugin_id)

        # Copy or symlink
        if plugin_dir != source_dir do
          File.mkdir_p!(plugin_dir)
          # Create symlink for development
          link_target = Path.join(plugin_dir, "source")
          File.rm(link_target)
          File.ln_s!(source_dir, link_target)
        end

        finalize_install(plugin_id, source_dir, plugin_dir)

      {:error, reason} ->
        {:error, {:invalid_plugin, reason}}
    end
  end

  defp install_git_plugin(url, plugins_dir, _opts) do
    plugin_id = url |> URI.parse() |> Map.get(:path, "") |> Path.basename(".git")
    plugin_dir = Path.join(plugins_dir, plugin_id)

    case System.cmd("git", ["clone", "--depth", "1", url, plugin_dir],
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        finalize_install(plugin_id, plugin_dir, plugin_dir)

      {output, code} ->
        Logger.error("git clone failed (exit #{code}): #{output}")
        File.rm_rf!(plugin_dir)
        {:error, {:git_clone_failed, output}}
    end
  end

  defp finalize_install(plugin_id, source_dir, _plugin_dir) do
    case Store.read_plugin_json(source_dir) do
      {:ok, meta} ->
        # Build registry entry
        entry = %{
          id: plugin_id,
          name: Map.get(meta, :name, plugin_id),
          version: Map.get(meta, :version, "0.0.0"),
          description: Map.get(meta, :description, ""),
          runtime: Map.get(meta, :runtime, "node"),
          path: source_dir,
          entry: Map.get(meta, :entry, "./index.js"),
          enabled: true,
          config: %{},
          installed_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          source: source_dir,
          provides: Map.get(meta, :provides, %{})
        }

        # Update registry
        case Store.load() do
          {:ok, registry} ->
            registry = Store.put_plugin(registry, plugin_id, entry)
            Store.save(registry)

          {:error, _} ->
            registry = %{version: 1, plugins: %{}}
            registry = Store.put_plugin(registry, plugin_id, entry)
            Store.save(registry)
        end

        # Copy skills to ~/.clawd/skills/ if present
        install_skills(source_dir, meta)

        # Create plugin struct
        plugin = %Plugin{
          id: plugin_id,
          name: entry.name,
          version: entry.version,
          description: entry.description,
          plugin_type: String.to_atom(entry.runtime),
          path: source_dir,
          enabled: true,
          config: %{},
          capabilities: infer_capabilities_from_provides(entry.provides),
          status: :loaded
        }

        Logger.info("Plugin installed: #{plugin_id} v#{entry.version}")
        {:ok, plugin}

      {:error, reason} ->
        {:error, {:invalid_plugin_manifest, reason}}
    end
  end

  defp install_skills(source_dir, meta) do
    skills_dirs =
      case Map.get(meta, :provides) do
        %{skills: paths} when is_list(paths) -> paths
        %{"skills" => paths} when is_list(paths) -> paths
        _ -> []
      end

    managed_skills_dir = Path.expand("~/.clawd/skills")
    File.mkdir_p!(managed_skills_dir)

    Enum.each(skills_dirs, fn skill_path ->
      full_path = Path.join(source_dir, skill_path)

      if File.dir?(full_path) do
        # Copy each skill subdirectory
        case File.ls(full_path) do
          {:ok, entries} ->
            Enum.each(entries, fn entry ->
              skill_dir = Path.join(full_path, entry)
              target_dir = Path.join(managed_skills_dir, entry)

              if File.dir?(skill_dir) && File.exists?(Path.join(skill_dir, "SKILL.md")) do
                # Symlink to avoid duplication
                File.rm_rf(target_dir)
                File.ln_s!(skill_dir, target_dir)
                Logger.debug("Skill linked: #{entry} → #{skill_dir}")
              end
            end)

          _ ->
            :ok
        end
      end
    end)
  end

  # ============================================================================
  # Private — Helpers
  # ============================================================================

  defp normalize_plugin_spec({module, config}) when is_atom(module) and is_map(config) do
    {module, config}
  end

  defp normalize_plugin_spec({module, config}) when is_atom(module) and is_list(config) do
    {module, Map.new(config)}
  end

  defp normalize_plugin_spec(module) when is_atom(module) do
    {module, %{}}
  end

  defp infer_capabilities(module) do
    caps = []
    caps = if function_exported?(module, :tools, 0), do: [:tools | caps], else: caps
    caps = if function_exported?(module, :channels, 0), do: [:channels | caps], else: caps
    caps = if function_exported?(module, :providers, 0), do: [:providers | caps], else: caps
    caps = if function_exported?(module, :hooks, 0), do: [:hooks | caps], else: caps
    caps
  end

  defp infer_capabilities_from_provides(provides) when is_map(provides) do
    caps = []

    tools = Map.get(provides, :tools, Map.get(provides, "tools", []))
    channels = Map.get(provides, :channels, Map.get(provides, "channels", []))
    providers = Map.get(provides, :providers, Map.get(provides, "providers", []))

    caps = if is_list(tools) && tools != [], do: [:tools | caps], else: caps
    caps = if is_list(channels) && channels != [], do: [:channels | caps], else: caps
    caps = if is_list(providers) && providers != [], do: [:providers | caps], else: caps
    caps
  end

  defp infer_capabilities_from_provides(_), do: []

  defp stop_plugin(%Plugin{plugin_type: :beam, module: module}, plugin_state)
       when not is_nil(module) do
    if function_exported?(module, :stop, 1) do
      try do
        module.stop(plugin_state)
      rescue
        _ -> :ok
      end
    end
  end

  defp stop_plugin(_, _), do: :ok

  defp persist_enabled_state(state, plugin_id, enabled?) do
    case state.registry do
      nil -> :ok
      registry ->
        updated = Store.set_enabled(registry, plugin_id, enabled?)
        Store.save(updated)
    end
  end
end
