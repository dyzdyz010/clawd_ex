defmodule ClawdEx.Sessions.SessionWorker do
  @moduledoc """
  会话工作进程 - 处理单个会话的消息和状态
  """
  use GenServer, restart: :transient

  alias ClawdEx.Repo
  alias ClawdEx.Sessions.{Session, Message}
  alias ClawdEx.AI.Chat
  alias ClawdEx.Memory

  require Logger

  defstruct [
    :session_key,
    :session_id,
    :agent_id,
    :model,
    :system_prompt,
    :messages,
    :channel,
    :tools
  ]

  # Client API

  def start_link(opts) do
    session_key = Keyword.fetch!(opts, :session_key)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(session_key))
  end

  @doc """
  发送消息到会话
  """
  @spec send_message(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def send_message(session_key, content) do
    GenServer.call(via_tuple(session_key), {:send_message, content}, 120_000)
  end

  @doc """
  获取会话历史
  """
  @spec get_history(String.t(), keyword()) :: [Message.t()]
  def get_history(session_key, opts \\ []) do
    GenServer.call(via_tuple(session_key), {:get_history, opts})
  end

  @doc """
  获取会话状态
  """
  @spec get_state(String.t()) :: map()
  def get_state(session_key) do
    GenServer.call(via_tuple(session_key), :get_state)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    session_key = Keyword.fetch!(opts, :session_key)
    agent_id = Keyword.get(opts, :agent_id)
    channel = Keyword.get(opts, :channel, "telegram")

    # 从数据库加载或创建会话
    session = load_or_create_session(session_key, agent_id, channel)

    # 加载消息历史
    messages = load_messages(session.id)

    state = %__MODULE__{
      session_key: session_key,
      session_id: session.id,
      agent_id: session.agent_id,
      model: session.model_override || get_agent_model(session.agent_id),
      system_prompt: get_agent_system_prompt(session.agent_id),
      messages: messages,
      channel: channel,
      tools: []
    }

    Logger.info("Session started: #{session_key}")
    {:ok, state}
  end

  @impl true
  def handle_call({:send_message, content}, _from, state) do
    # 1. 保存用户消息
    _user_message = save_message(state.session_id, %{
      role: :user,
      content: content
    })

    # 2. 构建消息历史
    messages = state.messages ++ [%{role: "user", content: content}]

    # 3. 可选：执行记忆搜索
    memory_context = if state.agent_id do
      case Memory.search(state.agent_id, content, limit: 3) do
        [] -> nil
        chunks ->
          context = Enum.map_join(chunks, "\n---\n", & &1.content)
          "[相关记忆]\n#{context}\n[/相关记忆]"
      end
    end

    # 4. 构建系统提示
    system = build_system_prompt(state.system_prompt, memory_context)

    # 5. 调用 AI
    case Chat.complete(state.model, messages, system: system, tools: state.tools) do
      {:ok, response} ->
        # 保存助手回复
        _assistant_message = save_message(state.session_id, %{
          role: :assistant,
          content: response.content,
          tool_calls: response.tool_calls,
          model: state.model,
          tokens_in: response.tokens_in,
          tokens_out: response.tokens_out
        })

        # 更新会话统计
        update_session_stats(state.session_id, response)

        # 更新状态
        new_messages = messages ++ [%{role: "assistant", content: response.content}]
        new_state = %{state | messages: new_messages}

        {:reply, {:ok, response}, new_state}

      {:error, reason} = error ->
        Logger.error("AI call failed: #{inspect(reason)}")
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:get_history, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 50)
    messages = Enum.take(state.messages, -limit)
    {:reply, messages, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, Map.from_struct(state), state}
  end

  # Private Functions

  defp via_tuple(session_key) do
    {:via, Registry, {ClawdEx.SessionRegistry, session_key}}
  end

  defp load_or_create_session(session_key, agent_id, channel) do
    case Repo.get_by(Session, session_key: session_key) do
      nil ->
        # 确保有 agent
        agent_id = agent_id || get_or_create_default_agent_id()

        %Session{}
        |> Session.changeset(%{
          session_key: session_key,
          channel: channel,
          agent_id: agent_id
        })
        |> Repo.insert!()

      session ->
        session
    end
  end

  defp load_messages(session_id) do
    import Ecto.Query

    Message
    |> where([m], m.session_id == ^session_id)
    |> order_by([m], asc: m.inserted_at)
    |> limit(100)
    |> Repo.all()
    |> Enum.map(fn m ->
      %{role: to_string(m.role), content: m.content}
    end)
  end

  defp save_message(session_id, attrs) do
    %Message{}
    |> Message.changeset(Map.put(attrs, :session_id, session_id))
    |> Repo.insert!()
  end

  defp update_session_stats(session_id, response) do
    import Ecto.Query

    tokens = (response.tokens_in || 0) + (response.tokens_out || 0)

    from(s in Session, where: s.id == ^session_id)
    |> Repo.update_all(
      inc: [token_count: tokens, message_count: 2],
      set: [last_activity_at: DateTime.utc_now()]
    )
  end

  defp get_agent_model(nil), do: "anthropic/claude-sonnet-4"
  defp get_agent_model(agent_id) do
    case Repo.get(ClawdEx.Agents.Agent, agent_id) do
      nil -> "anthropic/claude-sonnet-4"
      agent -> agent.default_model
    end
  end

  defp get_agent_system_prompt(nil), do: nil
  defp get_agent_system_prompt(agent_id) do
    case Repo.get(ClawdEx.Agents.Agent, agent_id) do
      nil -> nil
      agent -> agent.system_prompt
    end
  end

  defp get_or_create_default_agent_id do
    alias ClawdEx.Agents.Agent

    case Repo.get_by(Agent, name: "default") do
      nil ->
        %Agent{}
        |> Agent.changeset(%{name: "default"})
        |> Repo.insert!()
        |> Map.get(:id)

      agent ->
        agent.id
    end
  end

  defp build_system_prompt(base_prompt, nil), do: base_prompt
  defp build_system_prompt(nil, memory_context), do: memory_context
  defp build_system_prompt(base_prompt, memory_context) do
    "#{base_prompt}\n\n#{memory_context}"
  end
end
