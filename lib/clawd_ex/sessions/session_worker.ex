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
    :config
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
    timeout = Keyword.get(opts, :timeout, 120_000)
    GenServer.call(via_tuple(session_key), {:send_message, content, opts}, timeout)
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

    Logger.info("Session started: #{session_key}")
    {:ok, state}
  end

  @impl true
  def handle_call({:send_message, content, opts}, _from, state) do
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
          result = AgentLoop.run(new_state.loop_pid, content, opts)
          {:reply, result, new_state}

        {:ok, :fresh} ->
          # 更新最后活动时间
          update_last_activity(state.session_id)
          result = AgentLoop.run(state.loop_pid, content, opts)
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
      loop_state: loop_state
    }

    {:reply, response, state}
  end

  @impl true
  def handle_cast(:stop_run, state) do
    AgentLoop.stop_run(state.loop_pid)
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
    case Repo.get_by(Session, session_key: session_key) do
      nil ->
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
