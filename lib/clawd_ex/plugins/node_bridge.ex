defmodule ClawdEx.Plugins.NodeBridge do
  @moduledoc """
  Node.js Plugin Bridge — manages a sidecar process (plugin-host.mjs)
  and communicates via stdin/stdout JSON-RPC 2.0.

  All Node.js plugins share a single sidecar process.
  The bridge handles:
  - Plugin loading/unloading
  - Tool listing and invocation
  - Async notifications (plugin.log, channel.message, plugin.error)
  - Port crash recovery
  - Request timeouts (30s default)
  """

  use GenServer
  require Logger

  @default_timeout 30_000
  @restart_delay 1_000

  defstruct [
    :port,
    :node_cmd,
    :script_path,
    status: :starting,
    pending: %{},
    next_id: 1,
    buffer: ""
  ]

  # ============================================================================
  # Client API
  # ============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Load a plugin from the given directory with config"
  @spec load_plugin(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def load_plugin(plugin_dir, config \\ %{}) do
    GenServer.call(__MODULE__, {:load_plugin, plugin_dir, config}, @default_timeout + 5_000)
  catch
    :exit, {:noproc, _} -> {:error, :bridge_not_running}
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @doc "Unload a plugin by ID"
  @spec unload_plugin(String.t()) :: :ok | {:error, term()}
  def unload_plugin(plugin_id) do
    GenServer.call(__MODULE__, {:unload_plugin, plugin_id}, @default_timeout)
  catch
    :exit, {:noproc, _} -> {:error, :bridge_not_running}
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @doc """
  List tools for a plugin. Returns a plain list of tool spec maps.

  Each map has string keys: "name", "description", "parameters".
  """
  @spec list_tools(String.t()) :: [map()]
  def list_tools(plugin_id) do
    case GenServer.call(__MODULE__, {:list_tools, plugin_id}, @default_timeout) do
      {:ok, tools} -> tools
      {:error, _} -> []
    end
  catch
    :exit, {:noproc, _} -> []
    :exit, {:timeout, _} -> []
  end

  @doc """
  Call a tool on a plugin. Returns {:ok, result} | {:error, reason}.
  """
  @spec call_tool(String.t(), String.t(), map(), map()) :: {:ok, any()} | {:error, term()}
  def call_tool(plugin_id, tool_name, params \\ %{}, context \\ %{}) do
    GenServer.call(__MODULE__, {:call_tool, plugin_id, tool_name, params, context}, @default_timeout + 5_000)
  catch
    :exit, {:noproc, _} -> {:error, :bridge_not_running}
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @doc "Get bridge status"
  @spec status() :: map()
  def status do
    GenServer.call(__MODULE__, :status)
  catch
    :exit, {:noproc, _} -> %{status: :not_running}
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    state = %__MODULE__{
      node_cmd: find_node(),
      script_path: plugin_host_path()
    }

    case start_port(state) do
      {:ok, new_state} ->
        Logger.info("[NodeBridge] Started plugin-host sidecar")
        {:ok, new_state}

      {:error, reason} ->
        Logger.warning("[NodeBridge] Failed to start sidecar: #{inspect(reason)}, will retry")
        Process.send_after(self(), :restart_port, @restart_delay)
        {:ok, %{state | status: :error}}
    end
  end

  @impl true
  def handle_call({:load_plugin, plugin_dir, config}, from, %{status: :ready} = state) do
    {id, state} = next_id(state)
    params = %{"pluginDir" => plugin_dir, "config" => config}
    send_rpc(state.port, id, "plugin.load", params)
    state = put_pending(state, id, {:load_plugin, from})
    schedule_timeout(id)
    {:noreply, state}
  end

  def handle_call({:load_plugin, _, _}, _from, state) do
    {:reply, {:error, {:not_ready, state.status}}, state}
  end

  @impl true
  def handle_call({:unload_plugin, plugin_id}, from, %{status: :ready} = state) do
    {id, state} = next_id(state)
    params = %{"pluginId" => plugin_id}
    send_rpc(state.port, id, "plugin.unload", params)
    state = put_pending(state, id, {:unload_plugin, from})
    schedule_timeout(id)
    {:noreply, state}
  end

  def handle_call({:unload_plugin, _}, _from, state) do
    {:reply, {:error, {:not_ready, state.status}}, state}
  end

  @impl true
  def handle_call({:list_tools, plugin_id}, from, %{status: :ready} = state) do
    {id, state} = next_id(state)
    params = %{"pluginId" => plugin_id}
    send_rpc(state.port, id, "tool.list", params)
    state = put_pending(state, id, {:list_tools, from})
    schedule_timeout(id)
    {:noreply, state}
  end

  def handle_call({:list_tools, _}, _from, state) do
    {:reply, {:error, {:not_ready, state.status}}, state}
  end

  @impl true
  def handle_call({:call_tool, plugin_id, tool_name, params, context}, from, %{status: :ready} = state) do
    {id, state} = next_id(state)
    rpc_params = %{
      "pluginId" => plugin_id,
      "tool" => tool_name,
      "params" => params,
      "context" => context
    }
    send_rpc(state.port, id, "tool.call", rpc_params)
    state = put_pending(state, id, {:call_tool, from})
    schedule_timeout(id)
    {:noreply, state}
  end

  def handle_call({:call_tool, _, _, _, _}, _from, state) do
    {:reply, {:error, {:not_ready, state.status}}, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    info = %{
      status: state.status,
      pending_count: map_size(state.pending)
    }
    {:reply, info, state}
  end

  # ============================================================================
  # Port data handling
  # ============================================================================

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    state = handle_port_data(state, data)
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    Logger.warning("[NodeBridge] Sidecar exited with code #{code}")
    state = fail_all_pending(state, {:sidecar_exited, code})
    Process.send_after(self(), :restart_port, @restart_delay)
    {:noreply, %{state | status: :error, port: nil, buffer: ""}}
  end

  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    Logger.warning("[NodeBridge] Port terminated: #{inspect(reason)}")
    state = fail_all_pending(state, {:port_terminated, reason})
    Process.send_after(self(), :restart_port, @restart_delay)
    {:noreply, %{state | status: :error, port: nil, buffer: ""}}
  end

  def handle_info(:restart_port, state) do
    if state.port do
      # Already have a port, skip restart
      {:noreply, state}
    else
      case start_port(state) do
        {:ok, new_state} ->
          Logger.info("[NodeBridge] Sidecar restarted successfully")
          {:noreply, new_state}

        {:error, reason} ->
          Logger.error("[NodeBridge] Sidecar restart failed: #{inspect(reason)}")
          Process.send_after(self(), :restart_port, @restart_delay * 2)
          {:noreply, state}
      end
    end
  end

  def handle_info({:rpc_timeout, rpc_id}, state) do
    case Map.get(state.pending, rpc_id) do
      {_type, from} when not is_nil(from) ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, remove_pending(state, rpc_id)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(msg, state) do
    Logger.debug("[NodeBridge] Unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.port do
      try do
        Port.close(state.port)
      rescue
        _ -> :ok
      end
    end
    :ok
  end

  # ============================================================================
  # Private — Port management
  # ============================================================================

  defp start_port(state) do
    node_cmd = state.node_cmd
    script = state.script_path

    unless node_cmd do
      {:error, :node_not_found}
    else
      unless File.exists?(script) do
        {:error, {:script_not_found, script}}
      else
        try do
          port = Port.open(
            {:spawn_executable, node_cmd},
            [
              :binary,
              :exit_status,
              :use_stdio,
              {:args, [script]},
              {:env, []},
              {:line, 1_048_576}
            ]
          )
          {:ok, %{state | port: port, status: :ready, buffer: ""}}
        rescue
          e ->
            {:error, {:port_start_failed, Exception.message(e)}}
        end
      end
    end
  end

  defp find_node do
    System.find_executable("node")
  end

  defp plugin_host_path do
    Path.join(:code.priv_dir(:clawd_ex), "plugin-host/plugin-host.mjs")
  end

  # ============================================================================
  # Private — JSON-RPC communication
  # ============================================================================

  defp send_rpc(port, id, method, params) do
    msg = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => params
    }
    json = Jason.encode!(msg)
    Port.command(port, json <> "\n")
  end

  defp handle_port_data(state, {:eol, data}) do
    line = state.buffer <> to_string(data)
    state = %{state | buffer: ""}
    handle_json_line(state, String.trim(line))
  end

  defp handle_port_data(state, {:noeol, data}) do
    %{state | buffer: state.buffer <> to_string(data)}
  end

  defp handle_port_data(state, data) when is_binary(data) do
    # Fallback for non-line mode data
    buffer = state.buffer <> data
    {lines, remaining} = split_lines(buffer)
    state = %{state | buffer: remaining}

    Enum.reduce(lines, state, fn line, acc ->
      line = String.trim(line)
      if line != "", do: handle_json_line(acc, line), else: acc
    end)
  end

  defp split_lines(buffer) do
    case String.split(buffer, "\n", parts: :infinity) do
      [] -> {[], ""}
      parts ->
        {complete, [remaining]} = Enum.split(parts, -1)
        {complete, remaining}
    end
  end

  defp handle_json_line(state, "") do
    state
  end

  defp handle_json_line(state, line) do
    case Jason.decode(line) do
      {:ok, %{"id" => id, "result" => result}} when not is_nil(id) ->
        handle_response(state, id, result)

      {:ok, %{"id" => id, "error" => error}} when not is_nil(id) ->
        handle_error_response(state, id, error)

      {:ok, %{"method" => method, "params" => params}} ->
        handle_notification(method, params)
        state

      {:ok, _other} ->
        Logger.debug("[NodeBridge] Unrecognized JSON message: #{line}")
        state

      {:error, _reason} ->
        Logger.warning("[NodeBridge] Failed to decode JSON: #{String.slice(line, 0, 200)}")
        state
    end
  end

  defp handle_response(state, id, result) do
    case Map.get(state.pending, id) do
      {:load_plugin, from} ->
        state = remove_pending(state, id)
        GenServer.reply(from, {:ok, result})
        state

      {:unload_plugin, from} ->
        state = remove_pending(state, id)
        GenServer.reply(from, :ok)
        state

      {:list_tools, from} ->
        tools =
          case result do
            %{"tools" => t} when is_list(t) ->
              Enum.map(t, fn tool ->
                %{
                  "name" => tool["name"],
                  "description" => tool["description"],
                  "parameters" => tool["parameters"]
                }
              end)

            _ ->
              []
          end

        state = remove_pending(state, id)
        GenServer.reply(from, {:ok, tools})
        state

      {:call_tool, from} ->
        data = case result do
          %{"data" => d} -> d
          other -> other
        end
        state = remove_pending(state, id)
        GenServer.reply(from, {:ok, data})
        state

      nil ->
        Logger.warning("[NodeBridge] Response for unknown id: #{id}")
        state
    end
  end

  defp handle_error_response(state, id, error) do
    case Map.get(state.pending, id) do
      {_type, from} when not is_nil(from) ->
        message = error["message"] || inspect(error)
        code = error["code"] || -32000
        state = remove_pending(state, id)
        GenServer.reply(from, {:error, %{code: code, message: message}})
        state

      nil ->
        Logger.warning("[NodeBridge] Error for unknown id #{id}: #{inspect(error)}")
        state
    end
  end

  defp handle_notification("plugin.log", params) do
    plugin_id = params["pluginId"] || "unknown"
    level = params["level"] || "info"
    message = params["message"] || ""

    case level do
      "error" -> Logger.error("[Plugin:#{plugin_id}] #{message}")
      "warn" -> Logger.warning("[Plugin:#{plugin_id}] #{message}")
      "debug" -> Logger.debug("[Plugin:#{plugin_id}] #{message}")
      _ -> Logger.info("[Plugin:#{plugin_id}] #{message}")
    end
  end

  defp handle_notification("channel.message", params) do
    plugin_id = params["pluginId"] || "unknown"
    Logger.info("[NodeBridge] Channel message from plugin #{plugin_id}: #{inspect(params["message"])}")
    # TODO: Route to SessionManager when channel integration is ready
  end

  defp handle_notification("plugin.error", params) do
    plugin_id = params["pluginId"] || "unknown"
    error = params["error"] || "unknown error"
    Logger.error("[NodeBridge] Plugin error from #{plugin_id}: #{error}")
  end

  defp handle_notification(method, params) do
    Logger.debug("[NodeBridge] Unknown notification: #{method} #{inspect(params)}")
  end

  # ============================================================================
  # Private — Helpers
  # ============================================================================

  defp next_id(state) do
    {state.next_id, %{state | next_id: state.next_id + 1}}
  end

  defp put_pending(state, id, value) do
    %{state | pending: Map.put(state.pending, id, value)}
  end

  defp remove_pending(state, id) do
    %{state | pending: Map.delete(state.pending, id)}
  end

  defp fail_all_pending(state, reason) do
    Enum.each(state.pending, fn
      {_id, {_type, from}} when not is_nil(from) ->
        GenServer.reply(from, {:error, reason})
      _ ->
        :ok
    end)
    %{state | pending: %{}}
  end

  defp schedule_timeout(rpc_id) do
    Process.send_after(self(), {:rpc_timeout, rpc_id}, @default_timeout)
  end
end
