defmodule ClawdEx.MCP.Connection do
  @moduledoc """
  MCP Connection — manages a stdio-based connection to an MCP server.

  Uses Erlang Port to spawn and communicate with an MCP server process
  via stdin/stdout using JSON-RPC 2.0 over newline-delimited JSON.
  """

  use GenServer
  require Logger

  alias ClawdEx.MCP.Protocol

  @default_timeout 30_000
  @init_timeout 10_000

  defstruct [
    :name,
    :command,
    :args,
    :port,
    :status,
    :server_info,
    :capabilities,
    :tools,
    :env,
    pending: %{},
    next_id: 1,
    buffer: ""
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          command: String.t(),
          args: [String.t()],
          port: port() | nil,
          status: :connecting | :ready | :error | :closed,
          server_info: map() | nil,
          capabilities: map() | nil,
          tools: [map()] | nil,
          env: [{charlist(), charlist()}] | nil,
          pending: map(),
          next_id: integer(),
          buffer: String.t()
        }

  # ============================================================================
  # Public API
  # ============================================================================

  @doc "Start a connection to an MCP server"
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    gen_name = Keyword.get(opts, :gen_name, via_name(name))
    GenServer.start_link(__MODULE__, opts, name: gen_name)
  end

  @doc "List tools from the MCP server"
  def list_tools(server, timeout \\ @default_timeout) do
    GenServer.call(server, :list_tools, timeout)
  catch
    :exit, {:noproc, _} -> {:error, :not_running}
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @doc "Call a tool on the MCP server"
  def call_tool(server, tool_name, arguments \\ %{}, timeout \\ @default_timeout) do
    GenServer.call(server, {:call_tool, tool_name, arguments}, timeout)
  catch
    :exit, {:noproc, _} -> {:error, :not_running}
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @doc "Get connection status"
  def status(server) do
    GenServer.call(server, :status)
  catch
    :exit, {:noproc, _} -> {:error, :not_running}
  end

  @doc "Ping the MCP server"
  def ping(server, timeout \\ @default_timeout) do
    GenServer.call(server, :ping, timeout)
  catch
    :exit, {:noproc, _} -> {:error, :not_running}
  end

  @doc "Stop the connection"
  def stop(server) do
    GenServer.stop(server, :normal)
  catch
    :exit, {:noproc, _} -> :ok
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    command = Keyword.fetch!(opts, :command)
    args = Keyword.get(opts, :args, [])
    env = Keyword.get(opts, :env, [])

    state = %__MODULE__{
      name: name,
      command: command,
      args: args,
      env: normalize_env(env),
      status: :connecting
    }

    # Start the port in init
    case start_port(state) do
      {:ok, new_state} ->
        # Send initialize request
        send(self(), :do_initialize)
        {:ok, new_state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:list_tools, from, %{status: :ready} = state) do
    {id, state} = next_id(state)

    case Protocol.tools_list(id) do
      {:ok, json} ->
        send_to_port(state.port, json)
        state = put_pending(state, id, {:list_tools, from})
        {:noreply, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:list_tools, _from, %{status: status} = state) do
    {:reply, {:error, {:not_ready, status}}, state}
  end

  def handle_call({:call_tool, tool_name, arguments}, from, %{status: :ready} = state) do
    {id, state} = next_id(state)

    case Protocol.tools_call(id, tool_name, arguments) do
      {:ok, json} ->
        send_to_port(state.port, json)
        state = put_pending(state, id, {:call_tool, from})
        {:noreply, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:call_tool, _tool_name, _arguments}, _from, %{status: status} = state) do
    {:reply, {:error, {:not_ready, status}}, state}
  end

  def handle_call(:status, _from, state) do
    info = %{
      name: state.name,
      status: state.status,
      server_info: state.server_info,
      capabilities: state.capabilities,
      tools: state.tools
    }

    {:reply, {:ok, info}, state}
  end

  def handle_call(:ping, from, %{status: :ready} = state) do
    {id, state} = next_id(state)

    case Protocol.ping(id) do
      {:ok, json} ->
        send_to_port(state.port, json)
        state = put_pending(state, id, {:ping, from})
        {:noreply, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:ping, _from, %{status: status} = state) do
    {:reply, {:error, {:not_ready, status}}, state}
  end

  @impl true
  def handle_info(:do_initialize, state) do
    {id, state} = next_id(state)

    case Protocol.initialize(id) do
      {:ok, json} ->
        send_to_port(state.port, json)
        state = put_pending(state, id, {:initialize, nil})
        # Set a timeout for initialization
        Process.send_after(self(), {:init_timeout, id}, @init_timeout)
        {:noreply, state}

      {:error, reason} ->
        Logger.error("[MCP:#{state.name}] Failed to encode initialize: #{inspect(reason)}")
        {:noreply, %{state | status: :error}}
    end
  end

  def handle_info({:init_timeout, id}, state) do
    case Map.get(state.pending, id) do
      {:initialize, _} ->
        Logger.error("[MCP:#{state.name}] Initialize timed out")
        state = remove_pending(state, id)
        {:noreply, %{state | status: :error}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({port, {:data, data}}, %{port: port} = state) do
    state = handle_port_data(state, data)
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    Logger.warning("[MCP:#{state.name}] Server exited with code #{code}")
    state = fail_all_pending(state, {:server_exited, code})
    {:noreply, %{state | status: :closed, port: nil}}
  end

  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    Logger.warning("[MCP:#{state.name}] Port terminated: #{inspect(reason)}")
    state = fail_all_pending(state, {:port_terminated, reason})
    {:noreply, %{state | status: :closed, port: nil}}
  end

  def handle_info(msg, state) do
    Logger.debug("[MCP:#{state.name}] Unexpected message: #{inspect(msg)}")
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
  # Private
  # ============================================================================

  defp via_name(name) do
    {:via, Registry, {ClawdEx.MCP.Registry, {:connection, name}}}
  end

  defp start_port(state) do
    cmd = System.find_executable(state.command) || state.command

    port_opts = [
      :binary,
      :exit_status,
      :use_stdio,
      {:args, state.args},
      {:env, state.env || []}
    ]

    try do
      port = Port.open({:spawn_executable, cmd}, port_opts)
      {:ok, %{state | port: port}}
    rescue
      e ->
        Logger.error("[MCP:#{state.name}] Failed to start port: #{inspect(e)}")
        {:error, {:port_start_failed, Exception.message(e)}}
    end
  end

  defp send_to_port(port, json) do
    Port.command(port, json <> "\n")
  end

  defp handle_port_data(state, data) do
    buffer = state.buffer <> to_string(data)
    {lines, remaining} = split_lines(buffer)

    state = %{state | buffer: remaining}

    Enum.reduce(lines, state, fn line, acc ->
      line = String.trim(line)

      if line != "" do
        handle_json_line(acc, line)
      else
        acc
      end
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

  defp handle_json_line(state, line) do
    case Protocol.decode(line) do
      {:ok, %{type: :response} = msg} ->
        handle_response(state, msg)

      {:ok, %{type: :error} = msg} ->
        handle_error_response(state, msg)

      {:ok, %{type: :notification} = msg} ->
        handle_notification(state, msg)

      {:ok, %{type: :request} = msg} ->
        handle_server_request(state, msg)

      {:error, reason} ->
        Logger.warning("[MCP:#{state.name}] Failed to decode: #{inspect(reason)}, line: #{line}")
        state
    end
  end

  defp handle_response(state, %{id: id, result: result}) do
    case Map.get(state.pending, id) do
      {:initialize, _from} ->
        Logger.info("[MCP:#{state.name}] Initialized: #{inspect(result["serverInfo"])}")
        state = remove_pending(state, id)

        state = %{state |
          status: :ready,
          server_info: result["serverInfo"],
          capabilities: result["capabilities"]
        }

        # Send initialized notification
        case Protocol.initialized() do
          {:ok, json} -> send_to_port(state.port, json)
          _ -> :ok
        end

        state

      {:list_tools, from} ->
        tools = result["tools"] || []
        state = remove_pending(state, id)
        GenServer.reply(from, {:ok, tools})
        %{state | tools: tools}

      {:call_tool, from} ->
        state = remove_pending(state, id)
        GenServer.reply(from, {:ok, result})
        state

      {:ping, from} ->
        state = remove_pending(state, id)
        if from, do: GenServer.reply(from, :ok)
        state

      nil ->
        Logger.warning("[MCP:#{state.name}] Response for unknown id: #{id}")
        state
    end
  end

  defp handle_error_response(state, %{id: id, error: error}) do
    case Map.get(state.pending, id) do
      {_type, from} when not is_nil(from) ->
        state = remove_pending(state, id)
        GenServer.reply(from, {:error, error})
        state

      {_type, nil} ->
        state = remove_pending(state, id)
        Logger.warning("[MCP:#{state.name}] Error response (no caller): #{inspect(error)}")
        state

      nil ->
        Logger.warning("[MCP:#{state.name}] Error for unknown id: #{id}")
        state
    end
  end

  defp handle_notification(state, %{method: method, params: params}) do
    Logger.debug("[MCP:#{state.name}] Notification: #{method} #{inspect(params)}")

    case method do
      "notifications/tools/list_changed" ->
        # Server signals tools changed — auto re-fetch if ready
        if state.status == :ready do
          {id, state} = next_id(state)
          case Protocol.tools_list(id) do
            {:ok, json} ->
              send_to_port(state.port, json)
              put_pending(state, id, {:list_tools_refresh, nil})

            _ ->
              state
          end
        else
          state
        end

      _ ->
        state
    end
  end

  defp handle_server_request(state, %{id: _id, method: method}) do
    Logger.debug("[MCP:#{state.name}] Server request: #{method} (not implemented)")
    state
  end

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

  # Normalize env to charlist tuples expected by Port
  defp normalize_env(env) when is_map(env) do
    Enum.map(env, fn {k, v} ->
      {to_charlist(to_string(k)), to_charlist(to_string(v))}
    end)
  end

  defp normalize_env(env) when is_list(env) do
    Enum.map(env, fn
      {k, v} when is_binary(k) and is_binary(v) ->
        {to_charlist(k), to_charlist(v)}

      {k, v} when is_list(k) and is_list(v) ->
        {k, v}

      {k, v} ->
        {to_charlist(to_string(k)), to_charlist(to_string(v))}
    end)
  end

  defp normalize_env(_), do: []
end
