defmodule ClawdEx.Sessions.SessionWorker do
  @moduledoc """
  会话工作进程 - 管理会话状态并委托给 Agent.Loop 处理消息

  职责:
  - 管理会话生命周期
  - 启动/监控对应的 Agent.Loop
  - 提供会话查询接口
  """
  use GenServer, restart: :transient

  alias ClawdEx.Repo
  alias ClawdEx.AI.Models
  alias ClawdEx.Sessions.{Session, Message, Reset}
  alias ClawdEx.Agent.Loop, as: AgentLoop

  require Logger

  defstruct [
    :session_key,
    :session_id,
    :agent_id,
    :channel,
    :loop_pid,
    :config,
    # 跟踪是否有 agent 正在运行
    agent_running: false,
    # 缓存当前流式输出内容（用于页面切换后恢复）
    streaming_content: ""
  ]

  # Client API

  def start_link(opts) do
    session_key = Keyword.fetch!(opts, :session_key)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(session_key))
  end

  @doc """
  发送消息到会话 - 委托给 Agent.Loop
  """
  @spec send_message(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def send_message(session_key, content, opts \\ []) do
    # 默认 5 分钟超时，适合复杂的多工具任务
    timeout = Keyword.get(opts, :timeout, 300_000)
    GenServer.call(via_tuple(session_key), {:send_message, content, opts}, timeout)
  end

  @doc """
  异步发送消息（fire-and-forget，结果通过 PubSub 返回）
  """
  @spec send_message_async(String.t(), String.t(), keyword()) :: :ok
  def send_message_async(session_key, content, opts \\ []) do
    GenServer.cast(via_tuple(session_key), {:send_message_async, content, opts})
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

  @doc """
  停止当前运行
  """
  def stop_run(session_key) do
    GenServer.cast(via_tuple(session_key), :stop_run)
  end

  @doc """
  重置流式内容缓存（当 ChatLive 保存了当前内容后调用）
  """
  def reset_streaming_cache(session_key) do
    GenServer.cast(via_tuple(session_key), :reset_streaming_cache)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    session_key = Keyword.fetch!(opts, :session_key)
    agent_id = Keyword.get(opts, :agent_id)
    channel = Keyword.get(opts, :channel, "telegram")

    # 从数据库加载或创建会话
    session = load_or_create_session(session_key, agent_id, channel)

    # 构建配置
    config = %{
      default_model: get_agent_model(session.agent_id),
      workspace: get_agent_workspace(session.agent_id)
    }

    # 启动 Agent Loop
    {:ok, loop_pid} =
      AgentLoop.start_link(
        session_id: session.id,
        agent_id: session.agent_id,
        config: config
      )

    state = %__MODULE__{
      session_key: session_key,
      session_id: session.id,
      agent_id: session.agent_id,
      channel: channel,
      loop_pid: loop_pid,
      config: config
    }

    # 订阅 agent 事件以缓存 streaming content
    Phoenix.PubSub.subscribe(ClawdEx.PubSub, "agent:#{session.id}")

    Logger.info("Session started: #{session_key}")
    {:ok, state}
  end

  @impl true
  def handle_call({:send_message, content, opts}, _from, state) do
    # 确保 agent loop 超时与调用者超时一致（留 5 秒余量）
    # 默认 5 分钟，复杂任务需要更多时间
    caller_timeout = Keyword.get(opts, :timeout, 300_000)
    opts = Keyword.put(opts, :timeout, max(caller_timeout - 5000, 30_000))

    # 检查是否是重置触发器
    if Reset.is_reset_trigger?(content) do
      handle_reset_trigger(content, opts, state)
    else
      # 检查会话是否过期需要重置
      session = Repo.get!(Session, state.session_id)

      case Reset.should_reset?(session) do
        {:reset, reason} ->
          Logger.info("Session #{state.session_key} reset due to #{reason}")
          new_session = Reset.reset_session!(session)
          new_state = restart_with_new_session(state, new_session)
          result = safe_run_agent(new_state.loop_pid, content, opts)
          {:reply, result, new_state}

        {:ok, :fresh} ->
          # 更新最后活动时间
          update_last_activity(state.session_id)
          result = safe_run_agent(state.loop_pid, content, opts)
          {:reply, result, state}
      end
    end
  end

  @impl true
  def handle_call({:get_history, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 50)
    messages = load_messages(state.session_id, limit)
    {:reply, messages, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    loop_state =
      case AgentLoop.get_state(state.loop_pid) do
        {:ok, s, _data} -> s
        _ -> :unknown
      end

    response = %{
      session_key: state.session_key,
      session_id: state.session_id,
      agent_id: state.agent_id,
      channel: state.channel,
      loop_state: loop_state,
      agent_running: state.agent_running,
      streaming_content: state.streaming_content
    }

    {:reply, response, state}
  end

  # Wrapper to catch timeout and other errors, preventing SessionWorker crash
  defp safe_run_agent(loop_pid, content, opts) do
    try do
      AgentLoop.run(loop_pid, content, opts)
    catch
      :exit, {:timeout, _} ->
        Logger.warning("Agent run timed out for message: #{String.slice(content, 0, 50)}...")
        {:error, "Request timed out. The task may be too complex or the AI is taking too long."}

      :exit, reason ->
        Logger.error("Agent run failed: #{inspect(reason)}")
        {:error, "Agent error: #{inspect(reason)}"}
    end
  end

  @impl true
  def handle_cast(:stop_run, state) do
    AgentLoop.stop_run(state.loop_pid)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:reset_streaming_cache, state) do
    {:noreply, %{state | streaming_content: ""}}
  end

  @impl true
  def handle_cast({:send_message_async, content, opts}, state) do
    # 异步处理：启动 Task 来运行 agent，结果通过 PubSub 发送
    session_key = state.session_key
    loop_pid = state.loop_pid

    # 更新最后活动时间
    update_last_activity(state.session_id)

    # 标记 agent 正在运行
    state = %{state | agent_running: true}

    # 在后台 Task 中运行 agent
    # 注意：我们需要捕获 self() 来更新状态
    worker_pid = self()

    Task.start(fn ->
      result = safe_run_agent(loop_pid, content, opts)

      # 通过 PubSub 广播结果
      Phoenix.PubSub.broadcast(
        ClawdEx.PubSub,
        "session:#{session_key}",
        {:agent_result, result}
      )

      # 通知 worker agent 运行完成
      send(worker_pid, :agent_finished)
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info(:agent_finished, state) do
    # Agent 完成后清空 streaming_content
    {:noreply, %{state | agent_running: false, streaming_content: ""}}
  end

  # 缓存流式内容，以便页面切换后恢复
  @impl true
  def handle_info({:agent_chunk, _run_id, %{content: content}}, state) do
    new_content = (state.streaming_content || "") <> content
    {:noreply, %{state | streaming_content: new_content}}
  end

  # 新一轮推理开始时 - 不再清空 streaming_content
  # 让 ChatLive 来决定如何处理（它会保存为消息）
  # SessionWorker 只在 agent 完成时清空
  @impl true
  def handle_info({:agent_status, _run_id, :inferring, _details}, state) do
    # 保持 streaming_content 不变，让它累积
    # ChatLive 会在收到 :inferring 时把当前内容保存为消息
    {:noreply, state}
  end

  # 忽略其他 agent_status 事件
  @impl true
  def handle_info({:agent_status, _run_id, _status, _details}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, %{loop_pid: pid} = state) do
    Logger.warning("Agent loop died: #{inspect(reason)}, restarting...")

    {:ok, new_loop_pid} =
      AgentLoop.start_link(
        session_id: state.session_id,
        agent_id: state.agent_id,
        config: state.config
      )

    {:noreply, %{state | loop_pid: new_loop_pid}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Private Functions

  defp via_tuple(session_key) do
    {:via, Registry, {ClawdEx.SessionRegistry, session_key}}
  end

  defp handle_reset_trigger(content, opts, state) do
    Logger.info("Manual reset triggered for session #{state.session_key}")

    # 重置会话
    session = Repo.get!(Session, state.session_id)
    new_session = Reset.reset_session!(session)
    new_state = restart_with_new_session(state, new_session)

    # 检查是否有后续内容
    case Reset.extract_post_reset_content(content) do
      nil ->
        # 只是重置，发送确认消息
        {:reply, {:ok, "Session reset. How can I help you?"}, new_state}

      post_content ->
        # 有后续内容，继续处理
        result = AgentLoop.run(new_state.loop_pid, post_content, opts)
        {:reply, result, new_state}
    end
  end

  defp restart_with_new_session(state, new_session) do
    # 停止旧的 Agent Loop
    if state.loop_pid && Process.alive?(state.loop_pid) do
      GenServer.stop(state.loop_pid, :normal, 5000)
    end

    # 启动新的 Agent Loop
    config = %{
      default_model: get_agent_model(new_session.agent_id),
      workspace: get_agent_workspace(new_session.agent_id)
    }

    {:ok, new_loop_pid} =
      AgentLoop.start_link(
        session_id: new_session.id,
        agent_id: new_session.agent_id,
        config: config
      )

    %{
      state
      | session_id: new_session.id,
        agent_id: new_session.agent_id,
        loop_pid: new_loop_pid,
        config: config
    }
  end

  defp update_last_activity(session_id) do
    Repo.get!(Session, session_id)
    |> Session.changeset(%{last_activity_at: DateTime.utc_now()})
    |> Repo.update!()
  end

  defp load_or_create_session(session_key, agent_id, channel) do
    # 先尝试查找已存在的 session
    case Repo.get_by(Session, session_key: session_key) do
      nil ->
        # 不存在，创建新的
        create_new_session(session_key, agent_id, channel)

      %{state: :archived} = session ->
        # 存在但已归档，重新激活它
        session
        |> Session.changeset(%{state: :active})
        |> Repo.update!()

      session ->
        # 存在且活跃，直接返回
        session
    end
  end

  defp create_new_session(session_key, agent_id, channel) do
    agent_id = agent_id || get_or_create_default_agent_id()

    try do
      %Session{}
      |> Session.changeset(%{
        session_key: session_key,
        channel: channel,
        agent_id: agent_id
      })
      |> Repo.insert!()
    rescue
      Ecto.ConstraintError ->
        # 竞态条件：另一个进程创建了它，获取现有的
        Repo.get_by!(Session, session_key: session_key)
    end
  end

  defp load_messages(session_id, limit) do
    import Ecto.Query

    Message
    |> where([m], m.session_id == ^session_id)
    |> order_by([m], desc: m.inserted_at)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.reverse()
    |> Enum.map(fn m ->
      %{
        role: to_string(m.role),
        content: m.content,
        inserted_at: m.inserted_at
      }
    end)
  end

  defp get_agent_model(nil), do: Models.default()

  defp get_agent_model(agent_id) do
    case Repo.get(ClawdEx.Agents.Agent, agent_id) do
      nil -> Models.default()
      agent -> Models.resolve(agent.default_model)
    end
  end

  defp get_agent_workspace(nil), do: nil

  defp get_agent_workspace(agent_id) do
    case Repo.get(ClawdEx.Agents.Agent, agent_id) do
      nil -> nil
      agent -> agent.workspace_path
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
end
