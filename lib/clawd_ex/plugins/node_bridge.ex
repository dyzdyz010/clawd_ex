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
  @max_restart_delay 30_000
  @max_restart_attempts 20
  @startup_timeout 5_000
  # Well below JS MAX_SAFE_INTEGER (2^53 - 1) to prevent precision loss
  @max_rpc_id 2_000_000_000

  defstruct [
    :port,
    :node_cmd,
    :script_path,
    :startup_timer,
    status: :starting,
    pending: %{},
    next_id: 1,
    buffer: "",
    buffer_size: 0,
    startup_queue: [],
    restart_attempts: 0,
    current_restart_delay: @restart_delay
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
    timer_ref = schedule_timeout(id)
    state = put_pending(state, id, {:load_plugin, from, timer_ref})
    {:noreply, state}
  end

  def handle_call({:load_plugin, _, _} = call, from, %{status: :starting} = state) do
    {:noreply, enqueue_call(state, call, from)}
  end

  def handle_call({:load_plugin, _, _}, _from, state) do
    {:reply, {:error, {:not_ready, state.status}}, state}
  end

  @impl true
  def handle_call({:unload_plugin, plugin_id}, from, %{status: :ready} = state) do
    {id, state} = next_id(state)
    params = %{"pluginId" => plugin_id}
    send_rpc(state.port, id, "plugin.unload", params)
    timer_ref = schedule_timeout(id)
    state = put_pending(state, id, {:unload_plugin, from, timer_ref})
    {:noreply, state}
  end

  def handle_call({:unload_plugin, _} = call, from, %{status: :starting} = state) do
    {:noreply, enqueue_call(state, call, from)}
  end

  def handle_call({:unload_plugin, _}, _from, state) do
    {:reply, {:error, {:not_ready, state.status}}, state}
  end

  @impl true
  def handle_call({:list_tools, plugin_id}, from, %{status: :ready} = state) do
    {id, state} = next_id(state)
    params = %{"pluginId" => plugin_id}
    send_rpc(state.port, id, "tool.list", params)
    timer_ref = schedule_timeout(id)
    state = put_pending(state, id, {:list_tools, from, timer_ref})
    {:noreply, state}
  end

  def handle_call({:list_tools, _} = call, from, %{status: :starting} = state) do
    {:noreply, enqueue_call(state, call, from)}
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
    timer_ref = schedule_timeout(id)
    state = put_pending(state, id, {:call_tool, from, timer_ref})
    {:noreply, state}
  end

  def handle_call({:call_tool, _, _, _, _} = call, from, %{status: :starting} = state) do
    {:noreply, enqueue_call(state, call, from)}
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
    if state.startup_timer, do: Process.cancel_timer(state.startup_timer)
    state = fail_startup_queue(state, {:error, {:sidecar_exited, code}})
    state = fail_all_pending(state, {:sidecar_exited, code})
    Process.send_after(self(), :restart_port, @restart_delay)
    {:noreply, %{state | status: :error, port: nil, buffer: "", startup_timer: nil, startup_queue: []}}
  end

  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    Logger.warning("[NodeBridge] Port terminated: #{inspect(reason)}")
    if state.startup_timer, do: Process.cancel_timer(state.startup_timer)
    state = fail_startup_queue(state, {:error, {:port_terminated, reason}})
    state = fail_all_pending(state, {:port_terminated, reason})
    Process.send_after(self(), :restart_port, @restart_delay)
    {:noreply, %{state | status: :error, port: nil, buffer: "", startup_timer: nil, startup_queue: []}}
  end

  def handle_info(:startup_timeout, %{status: :starting} = state) do
    Logger.error("[NodeBridge] Sidecar failed to send host.ready within #{@startup_timeout}ms")
    # Fail all queued calls
    state = fail_startup_queue(state, {:error, :startup_timeout})
    # Close port and schedule restart
    if state.port do
      try do
        Port.close(state.port)
      rescue
        _ -> :ok
      end
    end
    Process.send_after(self(), :restart_port, @restart_delay)
    {:noreply, %{state | status: :error, port: nil, buffer: "", startup_timer: nil, startup_queue: []}}
  end

  def handle_info(:startup_timeout, state) do
    # Already transitioned past :starting, ignore
    {:noreply, state}
  end

  def handle_info(:restart_port, state) do
    if state.port do
      # Already have a port, skip restart
      {:noreply, state}
    else
      if state.restart_attempts >= @max_restart_attempts do
        Logger.error("[NodeBridge] Max restart attempts (#{@max_restart_attempts}) reached, giving up")
        {:noreply, %{state | status: :error}}
      else
        case start_port(state) do
          {:ok, new_state} ->
            Logger.info("[NodeBridge] Sidecar restarted successfully")
            {:noreply, %{new_state | restart_attempts: 0, current_restart_delay: @restart_delay}}

          {:error, reason} ->
            attempts = state.restart_attempts + 1
            next_delay = min(state.current_restart_delay * 2, @max_restart_delay)
            Logger.error("[NodeBridge] Sidecar restart failed (attempt #{attempts}): #{inspect(reason)}, retry in #{next_delay}ms")
            Process.send_after(self(), :restart_port, state.current_restart_delay)
            {:noreply, %{state | restart_attempts: attempts, current_restart_delay: next_delay}}
        end
      end
    end
  end

  def handle_info({:rpc_timeout, rpc_id}, state) do
    case Map.get(state.pending, rpc_id) do
      {_type, from, _timer_ref} when not is_nil(from) ->
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
          startup_timer = Process.send_after(self(), :startup_timeout, @startup_timeout)
          {:ok, %{state | port: port, status: :starting, buffer: "", startup_timer: startup_timer, startup_queue: []}}
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

  # I5: Maximum buffer size (10MB) to prevent OOM from oversized messages
  @max_buffer_size 10_485_760

  defp handle_port_data(%{buffer: :overflow} = state, {:eol, _data}) do
    Logger.warning("[NodeBridge] Discarding oversized message (exceeded #{@max_buffer_size} bytes)")
    %{state | buffer: "", buffer_size: 0}
  end

  defp handle_port_data(state, {:eol, data}) do
    line = state.buffer <> to_string(data)
    state = %{state | buffer: "", buffer_size: 0}
    handle_json_line(state, String.trim(line))
  end

  defp handle_port_data(state, {:noeol, data}) do
    chunk = to_string(data)
    new_size = state.buffer_size + byte_size(chunk)

    if new_size > @max_buffer_size do
      Logger.error("[NodeBridge] Buffer exceeded #{@max_buffer_size} bytes, discarding message")
      # Discard the oversized buffer but keep listening — next {:eol, _} will start fresh
      %{state | buffer: :overflow, buffer_size: new_size}
    else
      %{state | buffer: state.buffer <> chunk, buffer_size: new_size}
    end
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

      {:ok, %{"method" => "host.ready"}} ->
        handle_host_ready(state)

      {:ok, %{"method" => method} = msg} ->
        handle_notification(method, Map.get(msg, "params", %{}))
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
      {:load_plugin, from, timer_ref} ->
        cancel_timer(timer_ref)
        state = remove_pending(state, id)
        GenServer.reply(from, {:ok, result})
        state

      {:unload_plugin, from, timer_ref} ->
        cancel_timer(timer_ref)
        state = remove_pending(state, id)
        GenServer.reply(from, :ok)
        state

      {:list_tools, from, timer_ref} ->
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

        cancel_timer(timer_ref)
        state = remove_pending(state, id)
        GenServer.reply(from, {:ok, tools})
        state

      {:call_tool, from, timer_ref} ->
        data = case result do
          %{"data" => d} -> d
          other -> other
        end
        cancel_timer(timer_ref)
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
      {_type, from, timer_ref} when not is_nil(from) ->
        cancel_timer(timer_ref)
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

  defp handle_host_ready(%{status: :starting} = state) do
    Logger.info("[NodeBridge] Sidecar host.ready received, transitioning to :ready")
    # Cancel startup timer
    if state.startup_timer, do: Process.cancel_timer(state.startup_timer)
    # Flush any startup_timeout message
    receive do
      :startup_timeout -> :ok
    after
      0 -> :ok
    end
    state = %{state | status: :ready, startup_timer: nil}
    # Replay queued calls
    drain_startup_queue(state)
  end

  defp handle_host_ready(state) do
    # Already ready or in error state, ignore duplicate host.ready
    state
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
    id = state.next_id
    {id, %{state | next_id: rem(id + 1, @max_rpc_id)}}
  end

  defp put_pending(state, id, value) do
    %{state | pending: Map.put(state.pending, id, value)}
  end

  defp remove_pending(state, id) do
    %{state | pending: Map.delete(state.pending, id)}
  end

  defp fail_all_pending(state, reason) do
    Enum.each(state.pending, fn
      {_id, {_type, from, timer_ref}} when not is_nil(from) ->
        cancel_timer(timer_ref)
        GenServer.reply(from, {:error, reason})
      _ ->
        :ok
    end)
    %{state | pending: %{}}
  end

  defp schedule_timeout(rpc_id) do
    Process.send_after(self(), {:rpc_timeout, rpc_id}, @default_timeout)
  end

  defp enqueue_call(state, call, from) do
    %{state | startup_queue: state.startup_queue ++ [{call, from}]}
  end

  defp drain_startup_queue(state) do
    Enum.reduce(state.startup_queue, %{state | startup_queue: []}, fn {call, from}, acc ->
      # Re-dispatch calls now that we're :ready
      case call do
        {:load_plugin, plugin_dir, config} ->
          {id, acc} = next_id(acc)
          params = %{"pluginDir" => plugin_dir, "config" => config}
          send_rpc(acc.port, id, "plugin.load", params)
          timer_ref = schedule_timeout(id)
          put_pending(acc, id, {:load_plugin, from, timer_ref})

        {:unload_plugin, plugin_id} ->
          {id, acc} = next_id(acc)
          params = %{"pluginId" => plugin_id}
          send_rpc(acc.port, id, "plugin.unload", params)
          timer_ref = schedule_timeout(id)
          put_pending(acc, id, {:unload_plugin, from, timer_ref})

        {:list_tools, plugin_id} ->
          {id, acc} = next_id(acc)
          params = %{"pluginId" => plugin_id}
          send_rpc(acc.port, id, "tool.list", params)
          timer_ref = schedule_timeout(id)
          put_pending(acc, id, {:list_tools, from, timer_ref})

        {:call_tool, plugin_id, tool_name, params, context} ->
          {id, acc} = next_id(acc)
          rpc_params = %{
            "pluginId" => plugin_id,
            "tool" => tool_name,
            "params" => params,
            "context" => context
          }
          send_rpc(acc.port, id, "tool.call", rpc_params)
          timer_ref = schedule_timeout(id)
          put_pending(acc, id, {:call_tool, from, timer_ref})
      end
    end)
  end

  defp fail_startup_queue(state, error) do
    Enum.each(state.startup_queue, fn {_call, from} ->
      GenServer.reply(from, error)
    end)
    %{state | startup_queue: []}
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref) do
    Process.cancel_timer(ref)
    # Flush any already-delivered timeout message
    receive do
      {:rpc_timeout, _} -> :ok
    after
      0 -> :ok
    end
  end
end
