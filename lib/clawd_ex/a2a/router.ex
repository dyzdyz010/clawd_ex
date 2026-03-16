defmodule ClawdEx.A2A.Router do
  @moduledoc """
  A2A 消息路由器 — 负责 Agent 间通信的核心组件。

  职责:
  1. Agent 注册与发现（capabilities）
  2. 消息路由与投递（via PubSub topic "a2a:{agent_id}"）
  3. 请求/响应匹配（sync request with timeout）
  4. 消息持久化到数据库
  5. TTL 过期检查
  """
  use GenServer

  require Logger

  import Ecto.Query

  alias ClawdEx.A2A.Message
  alias ClawdEx.Repo

  @ttl_check_interval_ms 60_000

  # ============================================================================
  # Client API
  # ============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Register an agent with its capabilities.
  Capabilities is a list of strings describing what the agent can do.
  """
  @spec register(integer(), list(String.t())) :: :ok
  def register(agent_id, capabilities \\ []) do
    GenServer.call(__MODULE__, {:register, agent_id, capabilities})
  end

  @doc """
  Unregister an agent.
  """
  @spec unregister(integer()) :: :ok
  def unregister(agent_id) do
    GenServer.call(__MODULE__, {:unregister, agent_id})
  end

  @doc """
  Send an async message (notification or delegation). Fire-and-forget.
  Returns the message_id.
  """
  @spec send_message(integer(), integer(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def send_message(from_agent_id, to_agent_id, content, opts \\ []) do
    GenServer.call(__MODULE__, {:send, from_agent_id, to_agent_id, content, opts})
  end

  @doc """
  Send a sync request and wait for response.
  Returns {:ok, response_content} or {:error, :timeout}.
  """
  @spec request(integer(), integer(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def request(from_agent_id, to_agent_id, content, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    GenServer.call(__MODULE__, {:request, from_agent_id, to_agent_id, content, opts}, timeout + 5_000)
  end

  @doc """
  Respond to a request message.
  """
  @spec respond(String.t(), integer(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def respond(reply_to_message_id, from_agent_id, content, opts \\ []) do
    GenServer.call(__MODULE__, {:respond, reply_to_message_id, from_agent_id, content, opts})
  end

  @doc """
  Discover available agents and their capabilities.
  Options:
  - capability: filter by capability string (substring match)
  """
  @spec discover(keyword()) :: {:ok, list(map())}
  def discover(opts \\ []) do
    GenServer.call(__MODULE__, {:discover, opts})
  end

  @doc """
  Mark a message as processed.
  """
  @spec mark_processed(String.t()) :: :ok | {:error, term()}
  def mark_processed(message_id) do
    GenServer.cast(__MODULE__, {:mark_processed, message_id})
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    # State: registry of agent_id => %{capabilities: [...], registered_at: ...}
    # and pending_requests: message_id => {from_pid, timer_ref}
    schedule_ttl_check()

    {:ok,
     %{
       registry: %{},
       pending_requests: %{}
     }}
  end

  @impl true
  def handle_call({:register, agent_id, capabilities}, _from, state) do
    entry = %{
      capabilities: capabilities,
      registered_at: DateTime.utc_now()
    }

    new_registry = Map.put(state.registry, agent_id, entry)
    Logger.info("A2A: Agent #{agent_id} registered with capabilities: #{inspect(capabilities)}")
    {:reply, :ok, %{state | registry: new_registry}}
  end

  def handle_call({:unregister, agent_id}, _from, state) do
    new_registry = Map.delete(state.registry, agent_id)
    Logger.info("A2A: Agent #{agent_id} unregistered")
    {:reply, :ok, %{state | registry: new_registry}}
  end

  def handle_call({:send, from_agent_id, to_agent_id, content, opts}, _from, state) do
    msg_type = Keyword.get(opts, :type, "notification")
    metadata = Keyword.get(opts, :metadata, %{})
    ttl = Keyword.get(opts, :ttl, 300)
    message_id = Message.generate_id()

    attrs = %{
      message_id: message_id,
      from_agent_id: from_agent_id,
      to_agent_id: to_agent_id,
      type: msg_type,
      content: content,
      metadata: metadata,
      ttl_seconds: ttl,
      status: "pending"
    }

    case persist_and_deliver(attrs) do
      {:ok, _msg} ->
        {:reply, {:ok, message_id}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:request, from_agent_id, to_agent_id, content, opts}, from, state) do
    metadata = Keyword.get(opts, :metadata, %{})
    timeout = Keyword.get(opts, :timeout, 30_000)
    ttl = Keyword.get(opts, :ttl, div(timeout, 1000))
    message_id = Message.generate_id()

    attrs = %{
      message_id: message_id,
      from_agent_id: from_agent_id,
      to_agent_id: to_agent_id,
      type: "request",
      content: content,
      metadata: metadata,
      ttl_seconds: ttl,
      status: "pending"
    }

    case persist_and_deliver(attrs) do
      {:ok, _msg} ->
        # Set up timeout for the request
        timer_ref = Process.send_after(self(), {:request_timeout, message_id}, timeout)
        pending = Map.put(state.pending_requests, message_id, {from, timer_ref})
        {:noreply, %{state | pending_requests: pending}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:respond, reply_to_message_id, from_agent_id, content, opts}, _from, state) do
    metadata = Keyword.get(opts, :metadata, %{})
    message_id = Message.generate_id()

    # Find the original request to get the to_agent_id
    original = Repo.get_by(Message, message_id: reply_to_message_id)

    to_agent_id =
      if original, do: original.from_agent_id, else: nil

    attrs = %{
      message_id: message_id,
      from_agent_id: from_agent_id,
      to_agent_id: to_agent_id,
      type: "response",
      content: content,
      metadata: metadata,
      reply_to: reply_to_message_id,
      status: "pending"
    }

    case persist_and_deliver(attrs) do
      {:ok, _msg} ->
        # Check if there's a pending sync request waiting for this reply
        case Map.get(state.pending_requests, reply_to_message_id) do
          {caller, timer_ref} ->
            Process.cancel_timer(timer_ref)
            GenServer.reply(caller, {:ok, content})
            pending = Map.delete(state.pending_requests, reply_to_message_id)
            {:reply, {:ok, message_id}, %{state | pending_requests: pending}}

          nil ->
            {:reply, {:ok, message_id}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:discover, opts}, _from, state) do
    capability_filter = Keyword.get(opts, :capability)

    agents =
      state.registry
      |> Enum.map(fn {agent_id, info} ->
        %{
          agent_id: agent_id,
          capabilities: info.capabilities,
          registered_at: info.registered_at
        }
      end)
      |> then(fn agents ->
        if capability_filter do
          Enum.filter(agents, fn a ->
            Enum.any?(a.capabilities, &String.contains?(&1, capability_filter))
          end)
        else
          agents
        end
      end)

    {:reply, {:ok, agents}, state}
  end

  @impl true
  def handle_cast({:mark_processed, message_id}, state) do
    case Repo.get_by(Message, message_id: message_id) do
      nil ->
        :ok

      msg ->
        msg
        |> Message.changeset(%{status: "processed", processed_at: DateTime.utc_now()})
        |> Repo.update()
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:request_timeout, message_id}, state) do
    case Map.get(state.pending_requests, message_id) do
      {caller, _timer_ref} ->
        GenServer.reply(caller, {:error, :timeout})
        pending = Map.delete(state.pending_requests, message_id)
        {:noreply, %{state | pending_requests: pending}}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(:check_ttl, state) do
    expire_old_messages()
    schedule_ttl_check()
    {:noreply, state}
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp persist_and_deliver(attrs) do
    case %Message{} |> Message.changeset(attrs) |> Repo.insert() do
      {:ok, msg} ->
        # Deliver via PubSub
        deliver_to_agent(msg)
        {:ok, msg}

      {:error, changeset} ->
        Logger.error("A2A: Failed to persist message: #{inspect(changeset.errors)}")
        {:error, {:persist_failed, changeset.errors}}
    end
  end

  defp deliver_to_agent(msg) do
    if msg.to_agent_id do
      Phoenix.PubSub.broadcast(
        ClawdEx.PubSub,
        "a2a:#{msg.to_agent_id}",
        {:a2a_message, %{
          message_id: msg.message_id,
          from_agent_id: msg.from_agent_id,
          type: msg.type,
          content: msg.content,
          metadata: msg.metadata,
          reply_to: msg.reply_to
        }}
      )

      # Update status to delivered
      msg
      |> Message.changeset(%{status: "delivered"})
      |> Repo.update()
    end
  end

  defp schedule_ttl_check do
    Process.send_after(self(), :check_ttl, @ttl_check_interval_ms)
  end

  defp expire_old_messages do
    now = DateTime.utc_now()

    # Find pending/delivered messages that have exceeded their TTL
    from(m in Message,
      where: m.status in ["pending", "delivered"],
      select: m
    )
    |> Repo.all()
    |> Enum.each(fn msg ->
      expiry = DateTime.add(msg.inserted_at, msg.ttl_seconds, :second)

      if DateTime.compare(now, expiry) == :gt do
        Logger.debug("A2A: Expiring message #{msg.message_id} (TTL exceeded)")

        msg
        |> Message.changeset(%{status: "expired"})
        |> Repo.update()
      end
    end)
  end
end
