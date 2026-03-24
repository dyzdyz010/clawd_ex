defmodule ClawdEx.ACP.Session do
  @moduledoc """
  GenServer managing a single ACP session lifecycle.

  Each session wraps an external ACP runtime backend (e.g. CLI process)
  and provides:
  - Session creation/resume via the registered backend
  - Message dispatch (one turn at a time)
  - Streaming event reception → PubSub broadcast
  - Timeout handling
  - Graceful cleanup

  Started under `ClawdEx.ACP.SessionSupervisor` (DynamicSupervisor).
  """

  use GenServer
  require Logger

  alias ClawdEx.ACP.{Event, Registry, ChannelBridge}

  @type status :: :idle | :running | :done | :error

  defstruct [
    :session_key,
    :agent_id,
    :handle,
    :backend_module,
    :parent_session_key,
    :parent_session_id,
    :channel,
    :channel_to,
    :label,
    :mode,
    :cwd,
    :started_at,
    :timeout_ref,
    status: :idle,
    events: [],
    result_text: ""
  ]

  # Default turn timeout: 10 minutes
  @default_turn_timeout_ms 600_000

  # --- Client API ---

  @doc "Start a new ACP session under the SessionSupervisor."
  @spec start(map()) :: {:ok, pid()} | {:error, term()}
  def start(opts) do
    DynamicSupervisor.start_child(
      ClawdEx.ACP.SessionSupervisor,
      {__MODULE__, opts}
    )
  end

  def start_link(opts) do
    session_key = Map.fetch!(opts, :session_key)
    GenServer.start_link(__MODULE__, opts, name: via(session_key))
  end

  @doc "Run a turn (send task text) in the session. Async — results broadcast via PubSub."
  @spec run_turn(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def run_turn(session_key, text, opts \\ []) do
    GenServer.call(via(session_key), {:run_turn, text, opts})
  end

  @doc "Get the current status of an ACP session."
  @spec get_status(String.t()) :: {:ok, map()} | {:error, term()}
  def get_status(session_key) do
    GenServer.call(via(session_key), :get_status)
  catch
    :exit, _ -> {:error, :not_found}
  end

  @doc "Cancel the current turn."
  @spec cancel(String.t()) :: :ok | {:error, term()}
  def cancel(session_key) do
    GenServer.call(via(session_key), :cancel)
  catch
    :exit, _ -> {:error, :not_found}
  end

  @doc "Close and clean up the session."
  @spec close(String.t()) :: :ok
  def close(session_key) do
    GenServer.call(via(session_key), :close)
  catch
    :exit, _ -> :ok
  end

  @doc "List all active ACP sessions."
  @spec list_sessions() :: [map()]
  def list_sessions do
    ClawdEx.ACP.SessionSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.flat_map(fn
      {_, pid, _, _} when is_pid(pid) ->
        try do
          [GenServer.call(pid, :get_status, 5_000)]
        catch
          :exit, _ -> []
        end

      _ ->
        []
    end)
    |> Enum.filter(&match?({:ok, _}, &1))
    |> Enum.map(fn {:ok, s} -> s end)
  end

  # --- Server Callbacks ---

  @impl true
  def init(opts) do
    session_key = Map.fetch!(opts, :session_key)
    agent_id = Map.get(opts, :agent_id, "codex")

    state = %__MODULE__{
      session_key: session_key,
      agent_id: agent_id,
      parent_session_key: Map.get(opts, :parent_session_key),
      parent_session_id: Map.get(opts, :parent_session_id),
      channel: Map.get(opts, :channel),
      channel_to: Map.get(opts, :channel_to),
      label: Map.get(opts, :label, agent_id),
      mode: Map.get(opts, :mode, "run"),
      cwd: Map.get(opts, :cwd),
      started_at: DateTime.utc_now()
    }

    Logger.info("[ACP.Session] Starting session #{session_key} (agent=#{agent_id})")

    # Attempt to resolve backend and ensure session asynchronously
    {:ok, state, {:continue, :ensure_session}}
  end

  @impl true
  def handle_continue(:ensure_session, state) do
    case Registry.get_backend(state.agent_id) do
      {:ok, backend_module} ->
        session_opts = %{
          session_key: state.session_key,
          agent_id: state.agent_id,
          cwd: state.cwd
        }

        case backend_module.ensure_session(session_opts) do
          {:ok, handle} ->
            Logger.info("[ACP.Session] Backend session ready: #{state.session_key}")
            {:noreply, %{state | backend_module: backend_module, handle: handle}}

          {:error, reason} ->
            Logger.error("[ACP.Session] ensure_session failed: #{inspect(reason)}")
            broadcast_event(state, Event.error("ensure_session_failed", text: inspect(reason)))
            {:noreply, %{state | status: :error}}
        end

      {:error, reason} ->
        Logger.error("[ACP.Session] Backend not found for #{state.agent_id}: #{inspect(reason)}")
        broadcast_event(state, Event.error("backend_not_found", text: "No backend for agent: #{state.agent_id}"))
        {:noreply, %{state | status: :error}}
    end
  end

  @impl true
  def handle_call({:run_turn, _text, _opts}, _from, %{status: :running} = state) do
    {:reply, {:error, :already_running}, state}
  end

  def handle_call({:run_turn, _text, _opts}, _from, %{status: :error, handle: nil} = state) do
    {:reply, {:error, :session_not_ready}, state}
  end

  def handle_call({:run_turn, text, opts}, _from, state) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_turn_timeout_ms)

    # Start timeout timer
    timeout_ref = Process.send_after(self(), :turn_timeout, timeout_ms)

    # Kick off the turn in a linked task
    me = self()
    _task_pid =
      spawn_link(fn ->
        run_turn_task(me, state, text, opts)
      end)

    new_state = %{state |
      status: :running,
      timeout_ref: timeout_ref,
      result_text: "",
      events: []
    }

    {:reply, :ok, new_state}
  end

  def handle_call(:get_status, _from, state) do
    info = %{
      session_key: state.session_key,
      agent_id: state.agent_id,
      label: state.label,
      status: state.status,
      mode: state.mode,
      parent_session_key: state.parent_session_key,
      started_at: state.started_at
    }

    {:reply, {:ok, info}, state}
  end

  def handle_call(:cancel, _from, state) do
    if state.handle && state.backend_module do
      state.backend_module.cancel(state.handle)
    end

    cancel_timeout(state.timeout_ref)
    broadcast_event(state, Event.status("cancelled"))

    {:reply, :ok, %{state | status: :idle, timeout_ref: nil}}
  end

  def handle_call(:close, _from, state) do
    Logger.info("[ACP.Session] Closing session #{state.session_key}")

    if state.handle && state.backend_module do
      state.backend_module.close(state.handle)
    end

    cancel_timeout(state.timeout_ref)

    {:stop, :normal, :ok, state}
  end

  @impl true
  def handle_info({:acp_event, %Event{type: :text_delta} = event}, state) do
    new_text = state.result_text <> (event.text || "")
    broadcast_event(state, event)
    {:noreply, %{state | result_text: new_text, events: [event | state.events]}}
  end

  def handle_info({:acp_event, %Event{type: :tool_call} = event}, state) do
    broadcast_event(state, event)
    {:noreply, %{state | events: [event | state.events]}}
  end

  def handle_info({:acp_event, %Event{type: :done} = event}, state) do
    cancel_timeout(state.timeout_ref)

    broadcast_event(state, event)

    # Announce completion to parent
    announce_completion(state, {:ok, state.result_text})

    new_state = %{state |
      status: :done,
      timeout_ref: nil,
      events: [event | state.events]
    }

    # If mode is "run", schedule self-termination
    if state.mode == "run" do
      Process.send_after(self(), :self_terminate, 5_000)
    end

    {:noreply, new_state}
  end

  def handle_info({:acp_event, %Event{type: :error} = event}, state) do
    cancel_timeout(state.timeout_ref)

    broadcast_event(state, event)
    announce_completion(state, {:error, event.text || event.code || "unknown error"})

    {:noreply, %{state | status: :error, timeout_ref: nil, events: [event | state.events]}}
  end

  def handle_info({:acp_event, event}, state) do
    broadcast_event(state, event)
    {:noreply, %{state | events: [event | state.events]}}
  end

  def handle_info(:turn_timeout, state) do
    Logger.warning("[ACP.Session] Turn timed out: #{state.session_key}")

    # Attempt to cancel the backend turn
    if state.handle && state.backend_module do
      state.backend_module.cancel(state.handle)
    end

    timeout_event = Event.error("timeout", text: "Turn timed out")
    broadcast_event(state, timeout_event)
    announce_completion(state, {:error, :timeout})

    {:noreply, %{state | status: :error, timeout_ref: nil}}
  end

  def handle_info(:self_terminate, state) do
    Logger.info("[ACP.Session] Self-terminating run-mode session: #{state.session_key}")

    if state.handle && state.backend_module do
      state.backend_module.close(state.handle)
    end

    {:stop, :normal, state}
  end

  def handle_info(msg, state) do
    Logger.debug("[ACP.Session] Unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("[ACP.Session] Terminating #{state.session_key}: #{inspect(reason)}")

    if state.handle && state.backend_module do
      try do
        state.backend_module.close(state.handle)
      rescue
        _ -> :ok
      end
    end

    :ok
  end

  # --- Private Helpers ---

  defp run_turn_task(session_pid, state, text, opts) do
    case state.backend_module.run_turn(state.handle, text, opts) do
      {:ok, event_stream} ->
        Enum.each(event_stream, fn event ->
          send(session_pid, {:acp_event, event})
        end)

      {:error, reason} ->
        error_event = Event.error("run_turn_failed", text: inspect(reason))
        send(session_pid, {:acp_event, error_event})
    end
  end

  defp broadcast_event(state, event) do
    topic = "acp:session:#{state.session_key}"

    Phoenix.PubSub.broadcast(
      ClawdEx.PubSub,
      topic,
      {:acp_event, state.session_key, event}
    )

    # Also forward to channel bridge
    ChannelBridge.handle_event(state, event)
  end

  defp announce_completion(state, result) do
    duration_ms = DateTime.diff(DateTime.utc_now(), state.started_at, :millisecond)

    completion_data = %{
      childSessionKey: state.session_key,
      label: state.label,
      status: if(match?({:ok, _}, result), do: :completed, else: :failed),
      durationMs: duration_ms,
      runtime: "acp",
      agentId: state.agent_id,
      result: format_result(result)
    }

    # Broadcast to parent session via PubSub
    if state.parent_session_key do
      Phoenix.PubSub.broadcast(
        ClawdEx.PubSub,
        "session:#{state.parent_session_key}",
        {:subagent_completed, completion_data}
      )
    end

    if state.parent_session_id do
      Phoenix.PubSub.broadcast(
        ClawdEx.PubSub,
        "agent:#{state.parent_session_id}",
        {:subagent_completed, completion_data}
      )
    end

    # Announce to channel
    ChannelBridge.announce_completion(state, result, duration_ms)
  end

  defp format_result({:ok, text}) when is_binary(text), do: truncate(text, 2000)
  defp format_result({:ok, other}), do: inspect(other, limit: 50)
  defp format_result({:error, reason}), do: "Error: #{inspect(reason)}"

  defp truncate(str, max) when byte_size(str) > max do
    String.slice(str, 0, max - 3) <> "..."
  end

  defp truncate(str, _max), do: str

  defp cancel_timeout(nil), do: :ok
  defp cancel_timeout(ref), do: Process.cancel_timer(ref)

  defp via(session_key) do
    {:via, Elixir.Registry, {ClawdEx.ACP.SessionRegistry, session_key}}
  end
end
