defmodule ClawdEx.ACP.Backends.CLIBackend do
  @moduledoc """
  ACP backend that drives external CLI coding agents via Erlang Port.

  Implements `ClawdEx.ACP.Runtime` behaviour.

  Supports Claude Code, Codex, and Gemini CLI. Each agent is spawned
  as a Port process, receiving prompts on stdin and emitting events
  on stdout. The backend normalizes all output into `ClawdEx.ACP.Event`
  structs regardless of the underlying agent format.

  ## Supported Agents

  - **claude** — Claude Code CLI with `--print --output-format stream-json`.
    Produces structured JSON-lines that map directly to events.
  - **codex** — OpenAI Codex CLI. Plain text output wrapped as a
    single text_delta + done pair.
  - **gemini** — Google Gemini CLI. Plain text output, same wrapping.
  """

  @behaviour ClawdEx.ACP.Runtime

  use GenServer
  require Logger

  alias ClawdEx.ACP.Event

  # ===========================================================================
  # Agent Configurations
  # ===========================================================================

  @agent_configs %{
    "claude" => %{
      command: "claude",
      args: ["--print", "--output-format", "stream-json"],
      parser: :claude_json,
      timeout_ms: 600_000
    },
    "codex" => %{
      command: "codex",
      args: ["--quiet"],
      parser: :plain_text,
      timeout_ms: 600_000
    },
    "gemini" => %{
      command: "gemini",
      args: [],
      parser: :plain_text,
      timeout_ms: 600_000
    }
  }

  @type agent_id :: String.t()

  defstruct [
    :port,
    :agent_id,
    :config,
    :caller,
    :timeout_ref,
    :executable,
    buffer: "",
    events: [],
    status: :idle
  ]

  # ===========================================================================
  # Public API (convenience wrappers)
  # ===========================================================================

  @doc "Return the list of known agent IDs."
  @spec supported_agents() :: [agent_id()]
  def supported_agents, do: Map.keys(@agent_configs)

  @doc "Get the config map for an agent, or nil."
  @spec agent_config(agent_id()) :: map() | nil
  def agent_config(agent_id), do: Map.get(@agent_configs, agent_id)

  @doc "Check whether the given agent CLI is available on this machine."
  @spec agent_available?(agent_id()) :: boolean()
  def agent_available?(agent_id) do
    case Map.get(@agent_configs, agent_id) do
      nil -> false
      %{command: cmd} -> System.find_executable(cmd) != nil
    end
  end

  # ===========================================================================
  # Runtime Behaviour Implementation
  # ===========================================================================

  @doc """
  Ensure a session is ready for the given agent.

  Expects a map with at least `:agent_id`. Optional keys:
  - `:cwd`  — working directory for the agent process
  - `:env`  — environment variables as `[{charlist, charlist}]`
  - `:args` — extra CLI arguments appended to the defaults

  Returns `{:ok, handle}` or `{:error, reason}`.
  """
  @impl ClawdEx.ACP.Runtime
  def ensure_session(params) do
    agent_id = Map.fetch!(params, :agent_id)

    case Map.get(@agent_configs, agent_id) do
      nil ->
        {:error, {:unknown_agent, agent_id}}

      config ->
        executable = System.find_executable(config.command)

        if executable do
          extra_args = Map.get(params, :args, [])
          env = Map.get(params, :env, [])
          cwd = Map.get(params, :cwd)
          session_key = Map.get(params, :session_key, "acp:cli:#{agent_id}:#{System.unique_integer([:positive])}")

          {:ok, pid} =
            GenServer.start_link(__MODULE__, %{
              agent_id: agent_id,
              config: config,
              executable: executable,
              extra_args: extra_args,
              env: env,
              cwd: cwd
            })

          {:ok,
           %{
             session_key: session_key,
             backend: "cli",
             runtime_session_name: agent_id,
             cwd: cwd,
             pid: pid,
             agent_id: agent_id,
             config: config
           }}
        else
          {:error, {:agent_not_found, agent_id, config.command}}
        end
    end
  end

  @doc """
  Run a single turn: send a prompt to the agent and collect all events.

  Returns `{:ok, [Event.t()]}` when the agent finishes, or
  `{:error, reason}` on timeout / crash.
  """
  @impl ClawdEx.ACP.Runtime
  def run_turn(%{pid: pid} = _handle, prompt, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 600_000)
    GenServer.call(pid, {:run_turn, prompt}, timeout)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, {:noproc, _} -> {:error, :not_running}
  end

  @doc "Cancel an in-progress turn by killing the port."
  @impl ClawdEx.ACP.Runtime
  def cancel(%{pid: pid}) do
    GenServer.cast(pid, :cancel)
  catch
    :exit, {:noproc, _} -> :ok
  end

  @doc "Close and clean up the session."
  @impl ClawdEx.ACP.Runtime
  def close(%{pid: pid}) do
    GenServer.stop(pid, :normal)
  catch
    :exit, {:noproc, _} -> :ok
  end

  @doc "Get the current status of the session."
  @impl ClawdEx.ACP.Runtime
  def get_status(%{pid: pid}) do
    GenServer.call(pid, :get_status)
  catch
    :exit, {:noproc, _} -> {:error, :not_running}
  end

  @doc "Run a diagnostic check on CLI agent availability."
  @impl ClawdEx.ACP.Runtime
  def doctor do
    results =
      Enum.map(@agent_configs, fn {id, config} ->
        path = System.find_executable(config.command)
        {id, %{available: path != nil, path: path, parser: config.parser}}
      end)
      |> Map.new()

    {:ok, %{backend: "cli", agents: results}}
  end

  @doc """
  Return a Stream of events for a turn (lazy wrapper around run_turn).
  """
  @spec stream_turn(map(), String.t(), keyword()) :: Enumerable.t()
  def stream_turn(handle, prompt, opts \\ []) do
    Stream.resource(
      fn -> {handle, prompt, opts, false} end,
      fn
        {_handle, _prompt, _opts, true} ->
          {:halt, :done}

        {handle, prompt, opts, false} ->
          case run_turn(handle, prompt, opts) do
            {:ok, events} ->
              {events, {handle, prompt, opts, true}}

            {:error, reason} ->
              {[Event.error(inspect(reason), text: "Turn failed")],
               {handle, prompt, opts, true}}
          end
      end,
      fn _ -> :ok end
    )
  end

  # ===========================================================================
  # GenServer Callbacks
  # ===========================================================================

  @impl true
  def init(opts) do
    state = %__MODULE__{
      agent_id: opts.agent_id,
      config: opts.config,
      executable: opts[:executable] || System.find_executable(opts.config.command),
      status: :idle
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:run_turn, prompt}, from, %{status: :idle} = state) do
    executable = state.executable || System.find_executable(state.config.command) || state.config.command

    # Build args: base args + prompt as the last positional arg
    args = state.config.args ++ [prompt]

    port_opts = [
      :binary,
      :exit_status,
      :use_stdio,
      :stderr_to_stdout,
      {:args, args}
    ]

    try do
      port = Port.open({:spawn_executable, executable}, port_opts)

      timeout_ms = state.config.timeout_ms || 600_000
      timeout_ref = Process.send_after(self(), :turn_timeout, timeout_ms)

      {:noreply,
       %{
         state
         | port: port,
           caller: from,
           buffer: "",
           events: [],
           status: :running,
           timeout_ref: timeout_ref
       }}
    rescue
      e ->
        {:reply, {:error, {:port_start_failed, Exception.message(e)}}, state}
    end
  end

  def handle_call({:run_turn, _prompt}, _from, state) do
    {:reply, {:error, {:busy, state.status}}, state}
  end

  def handle_call(:get_status, _from, state) do
    {:reply, {:ok, %{status: state.status, agent_id: state.agent_id}}, state}
  end

  @impl true
  def handle_cast(:cancel, %{status: :running} = state) do
    close_port(state.port)
    cancel_timeout(state.timeout_ref)

    if state.caller do
      GenServer.reply(state.caller, {:error, :cancelled})
    end

    {:noreply, reset_state(state)}
  end

  def handle_cast(:cancel, state), do: {:noreply, state}

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    state = handle_port_data(state, data)
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, 0}}, %{port: port} = state) do
    # Normal exit — flush remaining buffer, add done event, reply to caller
    state = flush_buffer(state)

    # Only add done if we don't already have one (Claude produces its own)
    events =
      if Enum.any?(state.events, &(&1.type == :done)) do
        Enum.reverse(state.events)
      else
        Enum.reverse([Event.done() | state.events])
      end

    cancel_timeout(state.timeout_ref)
    GenServer.reply(state.caller, {:ok, events})
    {:noreply, reset_state(state)}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    # Non-zero exit — treat accumulated text as error context
    state = flush_buffer(state)
    cancel_timeout(state.timeout_ref)

    error_text =
      state.events
      |> Enum.filter(&(&1.type == :text_delta))
      |> Enum.map(& &1.text)
      |> Enum.join()
      |> String.trim()

    error_msg =
      if error_text != "" do
        "Agent exited with code #{code}: #{String.slice(error_text, 0, 500)}"
      else
        "Agent exited with code #{code}"
      end

    events = Enum.reverse([Event.error(error_msg) | state.events])
    GenServer.reply(state.caller, {:ok, events})
    {:noreply, reset_state(state)}
  end

  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    cancel_timeout(state.timeout_ref)

    if state.caller do
      GenServer.reply(state.caller, {:error, {:port_terminated, reason}})
    end

    {:noreply, reset_state(state)}
  end

  def handle_info(:turn_timeout, %{status: :running} = state) do
    Logger.warning("[CLIBackend:#{state.agent_id}] Turn timed out, killing port")
    close_port(state.port)

    if state.caller do
      GenServer.reply(state.caller, {:error, :timeout})
    end

    {:noreply, reset_state(state)}
  end

  def handle_info(:turn_timeout, state), do: {:noreply, state}

  def handle_info(msg, state) do
    Logger.debug("[CLIBackend:#{state.agent_id}] Unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    close_port(state.port)
    :ok
  end

  # ===========================================================================
  # Port Data Handling
  # ===========================================================================

  defp handle_port_data(state, data) do
    buffer = state.buffer <> to_string(data)

    case state.config.parser do
      :claude_json ->
        parse_json_lines(state, buffer)

      :plain_text ->
        # For plain text agents, accumulate everything in buffer,
        # flush on process exit
        %{state | buffer: buffer}
    end
  end

  defp parse_json_lines(state, buffer) do
    {lines, remaining} = split_lines(buffer)
    state = %{state | buffer: remaining}

    Enum.reduce(lines, state, fn line, acc ->
      line = String.trim(line)
      if line != "", do: parse_claude_json_line(acc, line), else: acc
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

  @doc """
  Parse a single Claude Code JSON line into an Event.

  Claude `--output-format stream-json` emits:
  - `{"type":"assistant","subtype":"text","text":"..."}`
  - `{"type":"assistant","subtype":"tool_use","name":"...","input":{...}}`
  - `{"type":"result","subtype":"success","cost_usd":0.01,...}`
  - `{"type":"result","subtype":"error","error":"..."}`
  """
  @spec parse_claude_event(String.t()) :: Event.t() | nil
  def parse_claude_event(json_str) do
    case Jason.decode(json_str) do
      {:ok, %{"type" => "assistant", "subtype" => "text"} = raw} ->
        Event.text_delta(raw["text"] || "")

      {:ok, %{"type" => "assistant", "subtype" => "tool_use"} = raw} ->
        tool_id = raw["name"] || "unknown"
        Event.tool_call(tool_id, tool_title: raw["name"], text: Jason.encode!(raw["input"] || %{}))

      {:ok, %{"type" => "result", "subtype" => "success"} = raw} ->
        cost = raw["cost_usd"]
        Event.done(stop_reason: "end_turn", text: if(cost, do: "cost: $#{cost}", else: nil))

      {:ok, %{"type" => "result", "subtype" => "error"} = raw} ->
        Event.error(raw["error"] || "unknown_error", text: raw["error"])

      {:ok, raw} ->
        # Unknown event type — pass through as text_delta if it has content
        if raw["text"] do
          Event.text_delta(raw["text"])
        else
          nil
        end

      {:error, _} ->
        # Not valid JSON — might be stderr noise, skip
        Logger.debug("[CLIBackend] Skipping non-JSON line: #{String.slice(json_str, 0, 100)}")
        nil
    end
  end

  defp parse_claude_json_line(state, line) do
    case parse_claude_event(line) do
      nil -> state
      event -> %{state | events: [event | state.events]}
    end
  end

  defp flush_buffer(%{buffer: ""} = state), do: state

  defp flush_buffer(%{config: %{parser: :plain_text}} = state) do
    text = String.trim(state.buffer)

    if text != "" do
      event = Event.text_delta(text)
      %{state | events: [event | state.events], buffer: ""}
    else
      %{state | buffer: ""}
    end
  end

  defp flush_buffer(%{config: %{parser: :claude_json}} = state) do
    line = String.trim(state.buffer)

    if line != "" do
      case parse_claude_event(line) do
        nil -> %{state | buffer: ""}
        event -> %{state | events: [event | state.events], buffer: ""}
      end
    else
      %{state | buffer: ""}
    end
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp close_port(nil), do: :ok

  defp close_port(port) do
    try do
      Port.close(port)
    rescue
      _ -> :ok
    end
  end

  defp cancel_timeout(nil), do: :ok
  defp cancel_timeout(ref), do: Process.cancel_timer(ref)

  defp reset_state(state) do
    %{state | status: :idle, port: nil, caller: nil, events: [], buffer: "", timeout_ref: nil}
  end
end
