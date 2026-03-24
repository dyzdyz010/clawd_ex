defmodule ClawdEx.A2A.Mailbox do
  @moduledoc """
  每个 Agent 的收件箱 — 缓存未处理的 A2A 消息。

  当 Agent 正忙时，消息排队等待。
  Agent Loop 在 idle 状态时通过 peek/1 检查收件箱。
  处理完消息后调用 ack/2 确认。

  消息按 priority 排序（数字越小优先级越高）。
  同优先级内保持 FIFO 顺序。

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

  @doc "Peek at the next pending message without removing it (highest priority = lowest number)"
  @spec peek(integer()) :: {:ok, map()} | :empty
  def peek(agent_id) do
    case Registry.lookup(ClawdEx.A2AMailboxRegistry, agent_id) do
      [{pid, _}] -> GenServer.call(pid, :peek)
      [] -> :empty
    end
  end

  @doc "Pop the next pending message (removes it from queue, highest priority first)"
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

  @doc "List all pending messages (sorted by priority)"
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
       inbox: [],
       seq: 0,
       processing: %{}
     }}
  end

  @impl true
  def handle_call(:peek, _from, state) do
    case state.inbox do
      [{_sort_key, msg} | _rest] -> {:reply, {:ok, msg}, state}
      [] -> {:reply, :empty, state}
    end
  end

  def handle_call(:pop, _from, state) do
    case state.inbox do
      [{_sort_key, msg} | rest] ->
        new_processing = Map.put(state.processing, msg.message_id, msg)
        {:reply, {:ok, msg}, %{state | inbox: rest, processing: new_processing}}

      [] ->
        {:reply, :empty, state}
    end
  end

  def handle_call(:count, _from, state) do
    {:reply, length(state.inbox), state}
  end

  def handle_call(:list, _from, state) do
    {:reply, Enum.map(state.inbox, fn {_sort_key, msg} -> msg end), state}
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

    # Priority defaults to 5 (normal) if not present
    priority = Map.get(msg, :priority, 5)
    seq = state.seq + 1
    # Sort key: {priority, sequence} — lower priority number = higher urgency
    # Within same priority, FIFO by sequence number
    sort_key = {priority, seq}

    new_inbox =
      insert_sorted(state.inbox, {sort_key, msg})

    # Notify the agent loop that there's a pending message
    Phoenix.PubSub.broadcast(
      ClawdEx.PubSub,
      "agent_mailbox:#{state.agent_id}",
      {:mailbox_message, state.agent_id, msg}
    )

    {:noreply, %{state | inbox: new_inbox, seq: seq}}
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp via_tuple(agent_id) do
    {:via, Registry, {ClawdEx.A2AMailboxRegistry, agent_id}}
  end

  # Insert into a sorted list maintaining {priority, seq} order (ascending)
  defp insert_sorted([], entry), do: [entry]

  defp insert_sorted([{existing_key, _} = head | tail], {new_key, _} = entry) do
    if new_key <= existing_key do
      [entry, head | tail]
    else
      [head | insert_sorted(tail, entry)]
    end
  end
end
