defmodule ClawdEx.A2A.Mailbox do
  @moduledoc """
  每个 Agent 的收件箱 — 缓存未处理的 A2A 消息。

  当 Agent 正忙时，消息排队等待。
  Agent Loop 在 idle 状态时通过 peek/1 检查收件箱。
  处理完消息后调用 ack/2 确认。

  每个 Mailbox 进程通过 Registry 注册，key 为 agent_id。
  """
  use GenServer

  require Logger

  # ============================================================================
  # Client API
  # ============================================================================

  def start_link(opts) do
    agent_id = Keyword.fetch!(opts, :agent_id)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(agent_id))
  end

  @doc "Start a mailbox for an agent (idempotent via DynamicSupervisor)"
  @spec ensure_started(integer()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(agent_id) do
    case Registry.lookup(ClawdEx.A2AMailboxRegistry, agent_id) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        DynamicSupervisor.start_child(
          ClawdEx.A2AMailboxSupervisor,
          {__MODULE__, agent_id: agent_id}
        )
    end
  end

  @doc "Peek at the next pending message without removing it"
  @spec peek(integer()) :: {:ok, map()} | :empty
  def peek(agent_id) do
    case Registry.lookup(ClawdEx.A2AMailboxRegistry, agent_id) do
      [{pid, _}] -> GenServer.call(pid, :peek)
      [] -> :empty
    end
  end

  @doc "Pop the next pending message (removes it from queue)"
  @spec pop(integer()) :: {:ok, map()} | :empty
  def pop(agent_id) do
    case Registry.lookup(ClawdEx.A2AMailboxRegistry, agent_id) do
      [{pid, _}] -> GenServer.call(pid, :pop)
      [] -> :empty
    end
  end

  @doc "Acknowledge that a message has been processed"
  @spec ack(integer(), String.t()) :: :ok
  def ack(agent_id, message_id) do
    case Registry.lookup(ClawdEx.A2AMailboxRegistry, agent_id) do
      [{pid, _}] -> GenServer.cast(pid, {:ack, message_id})
      [] -> :ok
    end
  end

  @doc "Get the number of pending messages"
  @spec count(integer()) :: non_neg_integer()
  def count(agent_id) do
    case Registry.lookup(ClawdEx.A2AMailboxRegistry, agent_id) do
      [{pid, _}] -> GenServer.call(pid, :count)
      [] -> 0
    end
  end

  @doc "List all pending messages"
  @spec list(integer()) :: [map()]
  def list(agent_id) do
    case Registry.lookup(ClawdEx.A2AMailboxRegistry, agent_id) do
      [{pid, _}] -> GenServer.call(pid, :list)
      [] -> []
    end
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    agent_id = Keyword.fetch!(opts, :agent_id)

    # Subscribe to A2A messages for this agent
    Phoenix.PubSub.subscribe(ClawdEx.PubSub, "a2a:#{agent_id}")

    Logger.debug("A2A Mailbox started for agent #{agent_id}")

    {:ok,
     %{
       agent_id: agent_id,
       inbox: :queue.new(),
       processing: %{}
     }}
  end

  @impl true
  def handle_call(:peek, _from, state) do
    case :queue.peek(state.inbox) do
      {:value, msg} -> {:reply, {:ok, msg}, state}
      :empty -> {:reply, :empty, state}
    end
  end

  def handle_call(:pop, _from, state) do
    case :queue.out(state.inbox) do
      {{:value, msg}, new_queue} ->
        new_processing = Map.put(state.processing, msg.message_id, msg)
        {:reply, {:ok, msg}, %{state | inbox: new_queue, processing: new_processing}}

      {:empty, _} ->
        {:reply, :empty, state}
    end
  end

  def handle_call(:count, _from, state) do
    {:reply, :queue.len(state.inbox), state}
  end

  def handle_call(:list, _from, state) do
    {:reply, :queue.to_list(state.inbox), state}
  end

  @impl true
  def handle_cast({:ack, message_id}, state) do
    # Mark as processed in the router
    ClawdEx.A2A.Router.mark_processed(message_id)
    new_processing = Map.delete(state.processing, message_id)
    {:noreply, %{state | processing: new_processing}}
  end

  @impl true
  def handle_info({:a2a_message, msg}, state) do
    Logger.debug(
      "A2A Mailbox for agent #{state.agent_id}: received #{msg.type} from agent #{msg.from_agent_id}"
    )

    new_inbox = :queue.in(msg, state.inbox)

    # Notify the agent loop that there's a pending message
    Phoenix.PubSub.broadcast(
      ClawdEx.PubSub,
      "agent_mailbox:#{state.agent_id}",
      {:mailbox_message, state.agent_id, msg}
    )

    {:noreply, %{state | inbox: new_inbox}}
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp via_tuple(agent_id) do
    {:via, Registry, {ClawdEx.A2AMailboxRegistry, agent_id}}
  end
end
