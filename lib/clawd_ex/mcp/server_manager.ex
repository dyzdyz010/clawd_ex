defmodule ClawdEx.MCP.ServerManager do
  @moduledoc """
  MCP Server Manager — manages lifecycle of MCP server connections.

  Responsible for starting, stopping, and monitoring MCP server processes.
  Reads server configuration from application config and runtime JSON file.
  """

  use GenServer
  require Logger

  alias ClawdEx.MCP.Connection

  @config_file "~/.clawd/mcp_servers.json"

  defstruct servers: %{}, config: %{}

  @type server_info :: %{
          pid: pid(),
          status: :connecting | :ready | :error | :closed,
          config: map(),
          started_at: DateTime.t()
        }

  # ============================================================================
  # Public API
  # ============================================================================

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Start an MCP server connection"
  @spec start_server(String.t(), map(), GenServer.server()) :: {:ok, pid()} | {:error, term()}
  def start_server(name, config, server \\ __MODULE__) do
    GenServer.call(server, {:start_server, name, config})
  end

  @doc "Stop an MCP server connection"
  @spec stop_server(String.t(), GenServer.server()) :: :ok | {:error, term()}
  def stop_server(name, server \\ __MODULE__) do
    GenServer.call(server, {:stop_server, name})
  end

  @doc "List all managed servers and their status"
  @spec list_servers(GenServer.server()) :: [{String.t(), server_info()}]
  def list_servers(server \\ __MODULE__) do
    GenServer.call(server, :list_servers)
  end

  @doc "Get the connection pid for a server"
  @spec get_connection(String.t(), GenServer.server()) :: {:ok, pid()} | {:error, term()}
  def get_connection(name, server \\ __MODULE__) do
    GenServer.call(server, {:get_connection, name})
  end

  @doc "Reload configuration and reconcile servers"
  @spec reload_config(GenServer.server()) :: :ok
  def reload_config(server \\ __MODULE__) do
    GenServer.call(server, :reload_config)
  end

  @doc "Load all MCP server configs (app config merged with runtime JSON)."
  @spec load_configs() :: map()
  def load_configs do
    app_config = Application.get_env(:clawd_ex, :mcp_servers, %{})

    file_config =
      case load_config_file() do
        {:ok, config} -> config
        {:error, _} -> %{}
      end

    merge_configs(app_config, file_config)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    config = Keyword.get(opts, :config, %{})
    state = %__MODULE__{config: config}

    # Auto-start servers from config (deferred to allow supervision tree to settle)
    send(self(), :autostart)

    {:ok, state}
  end

  @impl true
  def handle_call({:start_server, name, config}, _from, state) do
    if Map.has_key?(state.servers, name) do
      # Return existing pid
      {:reply, {:ok, state.servers[name].pid}, state}
    else
      case do_start_server(state, name, config) do
        {:ok, new_state} ->
          pid = new_state.servers[name].pid
          {:reply, {:ok, pid}, new_state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  def handle_call({:stop_server, name}, _from, state) do
    case Map.get(state.servers, name) do
      nil ->
        {:reply, {:error, :not_found}, state}

      info ->
        if Process.alive?(info.pid) do
          try do
            Connection.stop(info.pid)
          catch
            :exit, _ -> :ok
          end
        end

        state = %{state | servers: Map.delete(state.servers, name)}
        {:reply, :ok, state}
    end
  end

  def handle_call(:list_servers, _from, state) do
    servers =
      Enum.map(state.servers, fn {name, info} ->
        status =
          if Process.alive?(info.pid) do
            case Connection.status(info.pid) do
              {:ok, %{status: s}} -> s
              _ -> :unknown
            end
          else
            :closed
          end

        {name, %{info | status: status}}
      end)

    {:reply, servers, state}
  end

  def handle_call({:get_connection, name}, _from, state) do
    case Map.get(state.servers, name) do
      nil ->
        {:reply, {:error, :not_found}, state}

      info ->
        if Process.alive?(info.pid) do
          {:reply, {:ok, info.pid}, state}
        else
          {:reply, {:error, :connection_down}, state}
        end
    end
  end

  def handle_call(:reload_config, _from, state) do
    new_config = load_configs()

    # Stop servers no longer in config
    to_stop =
      Map.keys(state.servers) -- Enum.map(new_config, fn {k, _v} -> to_string(k) end)

    state =
      Enum.reduce(to_stop, state, fn name, acc ->
        case Map.get(acc.servers, name) do
          nil ->
            acc

          info ->
            if Process.alive?(info.pid) do
              try do
                Connection.stop(info.pid)
              catch
                :exit, _ -> :ok
              end
            end

            %{acc | servers: Map.delete(acc.servers, name)}
        end
      end)

    # Start new servers from config
    state =
      Enum.reduce(new_config, state, fn {name, server_config}, acc ->
        name_str = to_string(name)

        if Map.has_key?(acc.servers, name_str) do
          acc
        else
          if Map.get(server_config, :enabled, Map.get(server_config, "enabled", true)) do
            case do_start_server(acc, name_str, server_config) do
              {:ok, new_state} -> new_state
              {:error, _reason} -> acc
            end
          else
            acc
          end
        end
      end)

    {:reply, :ok, %{state | config: new_config}}
  end

  @impl true
  def handle_info(:autostart, state) do
    config = load_configs()

    state =
      Enum.reduce(config, state, fn {name, server_config}, acc ->
        name_str = to_string(name)
        enabled = Map.get(server_config, :enabled, Map.get(server_config, "enabled", true))

        if enabled do
          case do_start_server(acc, name_str, server_config) do
            {:ok, new_state} ->
              Logger.info("[MCP:ServerManager] Auto-started server: #{name_str}")
              new_state

            {:error, reason} ->
              Logger.warning("[MCP:ServerManager] Failed to auto-start #{name_str}: #{inspect(reason)}")
              acc
          end
        else
          acc
        end
      end)

    {:noreply, %{state | config: config}}
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    # Find and remove the server that went down
    case Enum.find(state.servers, fn {_name, info} -> info.pid == pid end) do
      {name, _info} ->
        Logger.warning("[MCP:ServerManager] Connection #{name} went down: #{inspect(reason)}")
        state = %{state | servers: Map.delete(state.servers, name)}
        {:noreply, state}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ============================================================================
  # Private
  # ============================================================================

  defp do_start_server(state, name, config) do
    command = config[:command] || config["command"]
    args = config[:args] || config["args"] || []
    env = config[:env] || config["env"] || []

    unless command do
      {:error, :missing_command}
    else
      conn_opts = [
        name: name,
        command: command,
        args: args,
        env: env,
        gen_name: nil
      ]

      case Connection.start_link(conn_opts) do
        {:ok, pid} ->
          Process.monitor(pid)

          info = %{
            pid: pid,
            status: :connecting,
            config: config,
            started_at: DateTime.utc_now()
          }

          {:ok, %{state | servers: Map.put(state.servers, name, info)}}

        {:error, reason} ->
          Logger.error("[MCP:ServerManager] Failed to start #{name}: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  defp load_config_file do
    path = Path.expand(@config_file)

    if File.exists?(path) do
      case File.read(path) do
        {:ok, content} ->
          case Jason.decode(content) do
            {:ok, %{"mcpServers" => servers}} when is_map(servers) ->
              {:ok, servers}

            {:ok, servers} when is_map(servers) ->
              {:ok, servers}

            {:error, reason} ->
              Logger.warning("[MCP:ServerManager] Failed to parse #{path}: #{inspect(reason)}")
              {:error, reason}

            _ ->
              {:error, :unexpected_format}
          end

        {:error, reason} ->
          Logger.warning("[MCP:ServerManager] Failed to read #{path}: #{inspect(reason)}")
          {:error, reason}
      end
    else
      {:error, :not_found}
    end
  end

  defp merge_configs(app_config, file_config) when is_map(app_config) and is_map(file_config) do
    Map.merge(app_config, file_config)
  end

  defp merge_configs(app_config, file_config) when is_list(app_config) do
    app_map = Map.new(app_config, fn
      {k, v} -> {to_string(k), v}
      %{id: id} = v -> {id, v}
      %{"id" => id} = v -> {id, v}
    end)

    merge_configs(app_map, file_config)
  end

  defp merge_configs(app_config, _file_config), do: app_config
end
