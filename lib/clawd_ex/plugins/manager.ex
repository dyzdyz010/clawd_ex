defmodule ClawdEx.Plugins.Manager do
  @moduledoc """
  Plugin Manager — GenServer for plugin lifecycle management.

  Loads plugins from config, initializes them, and provides
  aggregated access to plugin-provided tools and providers.
  """
  use GenServer

  require Logger

  alias ClawdEx.Plugins.Plugin

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

  @doc "Enable a plugin by name"
  @spec enable_plugin(String.t()) :: :ok | {:error, :not_found}
  def enable_plugin(name) do
    GenServer.call(__MODULE__, {:enable_plugin, name})
  end

  @doc "Disable a plugin by name"
  @spec disable_plugin(String.t()) :: :ok | {:error, :not_found}
  def disable_plugin(name) do
    GenServer.call(__MODULE__, {:disable_plugin, name})
  end

  @doc "Get all tools from enabled plugins"
  @spec get_tools() :: [module()]
  def get_tools do
    GenServer.call(__MODULE__, :get_tools)
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

  @doc "Reload plugins from config"
  @spec reload() :: :ok
  def reload do
    GenServer.call(__MODULE__, :reload)
  end

  # ============================================================================
  # Server
  # ============================================================================

  @impl true
  def init(_opts) do
    state = %{plugins: %{}, states: %{}}
    state = load_plugins(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:list_plugins, _from, state) do
    plugins = state.plugins |> Map.values() |> Enum.sort_by(& &1.name)
    {:reply, plugins, state}
  end

  def handle_call({:enable_plugin, name}, _from, state) do
    case Map.get(state.plugins, name) do
      nil ->
        {:reply, {:error, :not_found}, state}

      plugin ->
        updated = %{plugin | enabled: true}
        {:reply, :ok, put_in(state.plugins[name], updated)}
    end
  end

  def handle_call({:disable_plugin, name}, _from, state) do
    case Map.get(state.plugins, name) do
      nil ->
        {:reply, {:error, :not_found}, state}

      plugin ->
        updated = %{plugin | enabled: false}
        {:reply, :ok, put_in(state.plugins[name], updated)}
    end
  end

  def handle_call(:get_tools, _from, state) do
    tools =
      state.plugins
      |> Map.values()
      |> Enum.filter(& &1.enabled)
      |> Enum.flat_map(fn plugin ->
        if function_exported?(plugin.module, :tools, 0) do
          try do
            plugin.module.tools()
          rescue
            e ->
              Logger.warning("Plugin #{plugin.name} tools() failed: #{inspect(e)}")
              []
          end
        else
          []
        end
      end)

    {:reply, tools, state}
  end

  def handle_call(:get_providers, _from, state) do
    providers =
      state.plugins
      |> Map.values()
      |> Enum.filter(& &1.enabled)
      |> Enum.flat_map(fn plugin ->
        if function_exported?(plugin.module, :providers, 0) do
          try do
            plugin.module.providers()
          rescue
            e ->
              Logger.warning("Plugin #{plugin.name} providers() failed: #{inspect(e)}")
              []
          end
        else
          []
        end
      end)

    {:reply, providers, state}
  end

  def handle_call(:reload, _from, _state) do
    state = load_plugins(%{plugins: %{}, states: %{}})
    {:reply, :ok, state}
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp load_plugins(state) do
    plugin_configs = Application.get_env(:clawd_ex, :plugins, [])

    Enum.reduce(plugin_configs, state, fn plugin_spec, acc ->
      {module, config} = normalize_plugin_spec(plugin_spec)
      load_one_plugin(acc, module, config)
    end)
  end

  defp normalize_plugin_spec({module, config}) when is_atom(module) and is_map(config) do
    {module, config}
  end

  defp normalize_plugin_spec({module, config}) when is_atom(module) and is_list(config) do
    {module, Map.new(config)}
  end

  defp normalize_plugin_spec(module) when is_atom(module) do
    {module, %{}}
  end

  defp load_one_plugin(state, module, config) do
    try do
      name = module.name()
      version = module.version()
      description = module.description()

      case module.init(config) do
        {:ok, plugin_state} ->
          plugin = %Plugin{
            name: name,
            version: version,
            description: description,
            module: module,
            enabled: true,
            config: config
          }

          Logger.info("Plugin loaded: #{name} v#{version}")

          %{
            state
            | plugins: Map.put(state.plugins, name, plugin),
              states: Map.put(state.states, name, plugin_state)
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
end
