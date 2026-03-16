defmodule ClawdEx.Agent.OutputManager do
  @moduledoc """
  管理 Agent 运行期间的渐进式输出。

  每个 run 启动时，Agent Loop 调用 start/2 注册 session_id。
  输出段通过 PubSub 广播到 "output:{session_id}" topic，
  渠道层订阅该 topic 即可实时接收中间输出。

  消息格式:
  - {:output_segment, run_id, content, metadata} — 中间输出段
  - {:output_complete, run_id, final_content, metadata} — 运行完成
  """
  use GenServer

  require Logger

  defstruct [
    :run_id,
    :session_id,
    :delivery_mode,
    segments: [],
    delivered: []
  ]

  # ============================================================================
  # Client API
  # ============================================================================

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Register a new run for output tracking.
  """
  @spec start_run(String.t(), integer() | String.t()) :: :ok
  def start_run(run_id, session_id) do
    GenServer.cast(__MODULE__, {:start_run, run_id, session_id})
  end

  @doc """
  Deliver an intermediate output segment.
  Broadcasts immediately to "output:{session_id}" topic.
  """
  @spec deliver_segment(String.t(), String.t(), map()) :: :ok
  def deliver_segment(run_id, content, metadata \\ %{}) do
    GenServer.cast(__MODULE__, {:deliver_segment, run_id, content, metadata})
  end

  @doc """
  Deliver a progress summary after tool execution.
  """
  @spec deliver_progress(String.t(), String.t(), map()) :: :ok
  def deliver_progress(run_id, summary, metadata \\ %{}) do
    GenServer.cast(__MODULE__, {:deliver_progress, run_id, summary, metadata})
  end

  @doc """
  Signal that the run is complete and deliver final content.
  """
  @spec deliver_complete(String.t(), String.t(), map()) :: :ok
  def deliver_complete(run_id, final_content, metadata \\ %{}) do
    GenServer.cast(__MODULE__, {:deliver_complete, run_id, final_content, metadata})
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    # State: map of run_id => %{session_id, segments, ...}
    {:ok, %{runs: %{}}}
  end

  @impl true
  def handle_cast({:start_run, run_id, session_id}, state) do
    run_state = %__MODULE__{
      run_id: run_id,
      session_id: session_id,
      delivery_mode: :immediate,
      segments: [],
      delivered: []
    }

    {:noreply, put_in(state, [:runs, run_id], run_state)}
  end

  def handle_cast({:deliver_segment, run_id, content, metadata}, state) do
    case get_in(state, [:runs, run_id]) do
      nil ->
        Logger.debug("OutputManager: no run #{run_id} registered, broadcasting directly")
        # Still broadcast even without registration (graceful degradation)
        broadcast_segment(nil, run_id, content, metadata)
        {:noreply, state}

      run_state ->
        segment = %{content: content, metadata: metadata, delivered_at: DateTime.utc_now()}
        new_run = %{run_state | segments: run_state.segments ++ [segment], delivered: run_state.delivered ++ [segment]}

        broadcast_segment(run_state.session_id, run_id, content, metadata)

        {:noreply, put_in(state, [:runs, run_id], new_run)}
    end
  end

  def handle_cast({:deliver_progress, run_id, summary, metadata}, state) do
    case get_in(state, [:runs, run_id]) do
      nil ->
        {:noreply, state}

      run_state ->
        meta = Map.put(metadata, :type, :progress)
        broadcast_segment(run_state.session_id, run_id, summary, meta)
        {:noreply, state}
    end
  end

  def handle_cast({:deliver_complete, run_id, final_content, metadata}, state) do
    case get_in(state, [:runs, run_id]) do
      nil ->
        Logger.debug("OutputManager: completing unregistered run #{run_id}")
        {:noreply, state}

      run_state ->
        Phoenix.PubSub.broadcast(
          ClawdEx.PubSub,
          "output:#{run_state.session_id}",
          {:output_complete, run_id, final_content, metadata}
        )

        # Clean up run state
        {:noreply, %{state | runs: Map.delete(state.runs, run_id)}}
    end
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp broadcast_segment(session_id, run_id, content, metadata) do
    topic =
      if session_id do
        "output:#{session_id}"
      else
        # Fallback: use run_id as topic suffix
        "output:run:#{run_id}"
      end

    Phoenix.PubSub.broadcast(
      ClawdEx.PubSub,
      topic,
      {:output_segment, run_id, content, metadata}
    )
  end
end
