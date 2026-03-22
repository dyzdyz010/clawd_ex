defmodule ClawdEx.Plugins.Store do
  @moduledoc """
  Plugin Store — reads and writes the plugin registry file.

  The registry lives at `~/.clawd/plugins/registry.json` and tracks:
  - Installed plugins (id, version, runtime, path, enabled, config)
  - Installation metadata (installed_at, source)

  This is the persistent state of the plugin system. The Plugins.Manager
  reads it at startup and writes it when plugins are installed/removed.
  """

  require Logger

  @registry_filename "registry.json"
  @plugins_dir "plugins"

  @type plugin_entry :: %{
          id: String.t(),
          name: String.t(),
          version: String.t(),
          description: String.t(),
          runtime: String.t(),
          path: String.t(),
          entry: String.t(),
          enabled: boolean(),
          config: map(),
          installed_at: String.t(),
          source: String.t(),
          provides: map()
        }

  @type registry :: %{
          version: integer(),
          plugins: %{String.t() => plugin_entry()}
        }

  # ============================================================================
  # Public API
  # ============================================================================

  @doc "Get the plugins directory path"
  @spec plugins_dir() :: String.t()
  def plugins_dir do
    Path.expand("~/.clawd/#{@plugins_dir}")
  end

  @doc "Get the registry file path"
  @spec registry_path() :: String.t()
  def registry_path do
    Path.join(plugins_dir(), @registry_filename)
  end

  @doc "Load the plugin registry from disk"
  @spec load() :: {:ok, registry()} | {:error, term()}
  def load do
    path = registry_path()

    if File.exists?(path) do
      case File.read(path) do
        {:ok, content} ->
          case Jason.decode(content) do
            {:ok, data} ->
              {:ok, normalize_registry(data)}

            {:error, reason} ->
              Logger.error("Failed to parse plugin registry: #{inspect(reason)}")
              {:error, {:parse_error, reason}}
          end

        {:error, reason} ->
          Logger.error("Failed to read plugin registry: #{inspect(reason)}")
          {:error, reason}
      end
    else
      {:ok, empty_registry()}
    end
  end

  @doc "Save the plugin registry to disk (atomic: write to tmp file then rename)"
  @spec save(registry()) :: :ok | {:error, term()}
  def save(registry) do
    path = registry_path()
    dir = Path.dirname(path)

    # Ensure directory exists
    File.mkdir_p!(dir)

    case Jason.encode(registry, pretty: true) do
      {:ok, content} ->
        tmp_path = path <> ".tmp"

        with :ok <- File.write(tmp_path, content),
             :ok <- File.rename(tmp_path, path) do
          Logger.debug("Plugin registry saved: #{map_size(registry.plugins)} plugins")
          :ok
        else
          {:error, reason} ->
            # Clean up tmp file on failure
            File.rm(tmp_path)
            Logger.error("Failed to save plugin registry: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("Failed to encode plugin registry: #{inspect(reason)}")
        {:error, {:encode_error, reason}}
    end
  end

  @doc "Add or update a plugin entry in the registry"
  @spec put_plugin(registry(), String.t(), plugin_entry()) :: registry()
  def put_plugin(registry, plugin_id, entry) do
    %{registry | plugins: Map.put(registry.plugins, plugin_id, entry)}
  end

  @doc "Remove a plugin entry from the registry"
  @spec remove_plugin(registry(), String.t()) :: registry()
  def remove_plugin(registry, plugin_id) do
    %{registry | plugins: Map.delete(registry.plugins, plugin_id)}
  end

  @doc "Get a plugin entry by id"
  @spec get_plugin(registry(), String.t()) :: plugin_entry() | nil
  def get_plugin(registry, plugin_id) do
    Map.get(registry.plugins, plugin_id)
  end

  @doc "List all plugin entries"
  @spec list_plugins(registry()) :: [plugin_entry()]
  def list_plugins(registry) do
    Map.values(registry.plugins)
  end

  @doc "Set enabled state for a plugin"
  @spec set_enabled(registry(), String.t(), boolean()) :: registry()
  def set_enabled(registry, plugin_id, enabled?) do
    case Map.get(registry.plugins, plugin_id) do
      nil ->
        registry

      entry ->
        updated = Map.put(entry, :enabled, enabled?)
        put_plugin(registry, plugin_id, updated)
    end
  end

  @doc "Update plugin config"
  @spec set_config(registry(), String.t(), map()) :: registry()
  def set_config(registry, plugin_id, config) do
    case Map.get(registry.plugins, plugin_id) do
      nil ->
        registry

      entry ->
        updated = Map.put(entry, :config, config)
        put_plugin(registry, plugin_id, updated)
    end
  end

  @doc """
  Read a plugin.json file from a plugin directory.
  Returns normalized plugin metadata.
  """
  @spec read_plugin_json(String.t()) :: {:ok, map()} | {:error, term()}
  def read_plugin_json(plugin_dir) do
    # Try plugin.json first, then openclaw.plugin.json, then package.json
    candidates = [
      Path.join(plugin_dir, "plugin.json"),
      Path.join(plugin_dir, "openclaw.plugin.json"),
      Path.join(plugin_dir, "package.json")
    ]

    case Enum.find(candidates, &File.exists?/1) do
      nil ->
        {:error, :no_plugin_manifest}

      path ->
        case File.read(path) do
          {:ok, content} ->
            case Jason.decode(content) do
              {:ok, data} ->
                {:ok, normalize_plugin_json(data, plugin_dir)}

              {:error, reason} ->
                {:error, {:parse_error, reason}}
            end

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp empty_registry do
    %{version: 1, plugins: %{}}
  end

  defp normalize_registry(data) when is_map(data) do
    plugins =
      data
      |> Map.get("plugins", %{})
      |> Enum.map(fn {k, v} -> {k, normalize_entry(v)} end)
      |> Map.new()

    %{
      version: Map.get(data, "version", 1),
      plugins: plugins
    }
  end

  defp normalize_entry(entry) when is_map(entry) do
    %{
      id: Map.get(entry, "id", Map.get(entry, :id, "")),
      name: Map.get(entry, "name", Map.get(entry, :name, "")),
      version: Map.get(entry, "version", Map.get(entry, :version, "0.0.0")),
      description: Map.get(entry, "description", Map.get(entry, :description, "")),
      runtime: Map.get(entry, "runtime", Map.get(entry, :runtime, "beam")),
      path: Map.get(entry, "path", Map.get(entry, :path, "")),
      entry: Map.get(entry, "entry", Map.get(entry, :entry, "")),
      enabled: Map.get(entry, "enabled", Map.get(entry, :enabled, true)),
      config: Map.get(entry, "config", Map.get(entry, :config, %{})),
      installed_at: Map.get(entry, "installed_at", Map.get(entry, :installed_at, "")),
      source: Map.get(entry, "source", Map.get(entry, :source, "manual")),
      provides: Map.get(entry, "provides", Map.get(entry, :provides, %{}))
    }
  end

  defp normalize_plugin_json(data, plugin_dir) do
    # Handle both plugin.json and package.json formats
    openclaw = Map.get(data, "openclaw", %{})
    plugin_json = if Map.has_key?(data, "id"), do: data, else: %{}

    id =
      Map.get(plugin_json, "id") ||
        Map.get(openclaw, "id") ||
        Map.get(data, "name", Path.basename(plugin_dir))

    # Determine runtime
    runtime =
      cond do
        Map.has_key?(plugin_json, "runtime") -> Map.get(plugin_json, "runtime")
        Map.has_key?(data, "main") -> "node"
        File.exists?(Path.join(plugin_dir, "index.js")) -> "node"
        File.exists?(Path.join(plugin_dir, "beams")) -> "beam"
        true -> "node"
      end

    entry =
      Map.get(plugin_json, "entry") ||
        Map.get(data, "main") ||
        "./index.js"

    provides =
      Map.get(plugin_json, "provides") ||
        %{
          channels: Map.get(plugin_json, "channels", []),
          tools: [],
          skills: Map.get(plugin_json, "skills", []),
          providers: []
        }

    %{
      id: id,
      name: Map.get(data, "name", id),
      version: Map.get(data, "version", "0.0.0"),
      description: Map.get(data, "description", ""),
      runtime: runtime,
      entry: entry,
      path: plugin_dir,
      provides: provides,
      config_schema: Map.get(plugin_json, "config_schema") || Map.get(data, "configSchema", %{})
    }
  end
end
