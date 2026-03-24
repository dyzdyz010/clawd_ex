defmodule ClawdEx.Sessions.SessionWorker do
  @moduledoc """
  会话工作进程 - 管理会话状态并委托给 Agent.Loop 处理消息

  职责:
  - 管理会话生命周期
  - 启动/监控对应的 Agent.Loop
  - 提供会话查询接口
  - Heartbeat 定时器（周期性触发 agent heartbeat）
  - Always-On 模式（持久化、crash recovery）
  """
  use GenServer, restart: :transient

  alias ClawdEx.Repo
  alias ClawdEx.AI.Models
  alias ClawdEx.Sessions.{Session, Message, Reset}
  alias ClawdEx.Agent.Loop, as: AgentLoop
  alias ClawdEx.A2A.Router, as: A2ARouter

  require Logger

  @default_heartbeat_prompt "HEARTBEAT check. Reply HEARTBEAT_OK if nothing needs attention."
  @recovery_message_count 20

  defstruct [
    :session_key,
    :session_id,
    :agent_id,
    :channel,
    :loop_pid,
    :config,
    :heartbeat_ref,
    # 跟踪是否有 agent 正在运行
    agent_running: false,
    # 缓存当前流式输出内容（用于页面切换后恢复）
    streaming_content: "",
    # 是否已向 A2A Router 注册
    a2a_registered: false
  ]

  # Client API

  @doc """
  Override child_spec to support dynamic restart strategy.
  Always-on agents use :permanent restart; others use :transient.
  """
  def child_spec(opts) do
    restart = Keyword.get(opts, :restart, :transient)

    %{
      id: {__MODULE__, Keyword.fetch!(opts, :session_key)},
      start: {__MODULE__, :start_link, [opts]},
      restart: restart,
      type: :worker
    }
  end

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
    # Trap exits so terminate/2 is called on shutdown (needed for A2A unregister)
    Process.flag(:trap_exit, true)

    session_key = Keyword.fetch!(opts, :session_key)
    agent_id = Keyword.get(opts, :agent_id)
    channel = Keyword.get(opts, :channel, "telegram")

    # 从数据库加载或创建会话（graceful handling for DB unavailability）
    try do
      session = load_or_create_session(session_key, agent_id, channel)

      # 构建配置
      config = %{
        default_model: get_agent_model(session.agent_id),
        workspace: get_agent_workspace(session.agent_id),
        channel: channel,
        model_override: session.model_override
      }

      # 启动 Agent Loop
      {:ok, loop_pid} =
        AgentLoop.start_link(
          session_id: session.id,
          agent_id: session.agent_id,
          config: config
        )

      # Monitor the loop process so we detect crashes
      Process.monitor(loop_pid)

      # Load agent to check always_on / heartbeat config
      agent = load_agent(session.agent_id)

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

      # Session recovery: load recent messages for crash recovery context
      maybe_recover_context(session, agent)

      # Schedule heartbeat timer if configured
      state = maybe_schedule_heartbeat(state, agent)

      # A2A auto-register: if agent has capabilities, register with A2A Router
      state = maybe_a2a_register(state, agent)

      Logger.info("Session started: #{session_key}")
      {:ok, state}
    rescue
      e ->
        Logger.warning("Failed to start session #{session_key}: #{Exception.message(e)}")
        # Use :shutdown to prevent supervisor restart loops
        {:stop, {:shutdown, {:db_unavailable, Exception.message(e)}}}
    catch
      :exit, reason ->
        Logger.warning("Failed to start session #{session_key}: #{inspect(reason)}")
        {:stop, {:shutdown, {:db_unavailable, reason}}}
    end
  end

  @impl true
  def handle_call({:send_message, content, opts}, _from, state) do
    # 确保 agent loop 超时与调用者超时一致（留 5 秒余量）
    # 默认 5 分钟，复杂任务需要更多时间
    caller_timeout = Keyword.get(opts, :timeout, 300_000)
    opts = Keyword.put(opts, :timeout, max(caller_timeout - 5000, 30_000))

    try do
      # 检查是否是重置触发器
      if Reset.is_reset_trigger?(content) do
        handle_reset_trigger(content, opts, state)
      else
        # 检查会话是否过期需要重置
        case Repo.get(Session, state.session_id) do
          nil ->
            Logger.error("Session #{state.session_key} not found in DB (id=#{state.session_id})")
            {:reply, {:error, "Session not found"}, state}

          session ->
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
                # Refresh model_override from DB (may have changed via session_status tool)
                opts = maybe_apply_model_override(session, opts)
                result = safe_run_agent(state.loop_pid, content, opts)
                {:reply, result, state}
            end
        end
      end
    rescue
      e ->
        Logger.warning("Session #{state.session_key} DB error in send_message: #{Exception.message(e)}")
        {:reply, {:error, "Session DB unavailable: #{Exception.message(e)}"}, state}
    catch
      :exit, reason ->
        Logger.warning("Session #{state.session_key} exit in send_message: #{inspect(reason)}")
        {:reply, {:error, "Session unavailable"}, state}
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

    # 更新最后活动时间 (ignore DB errors)
    safe_update_last_activity(state.session_id)

    # Refresh model_override from DB for async path too
    opts =
      case Repo.get(Session, state.session_id) do
        nil -> opts
        session -> maybe_apply_model_override(session, opts)
      end

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

  # Heartbeat timer handler
  @impl true
  def handle_info(:heartbeat, state) do
    if state.agent_running do
      # Agent is busy — skip this heartbeat, schedule next one
      Logger.debug("Heartbeat skipped for #{state.session_key}: agent is busy")
      state = reschedule_heartbeat(state)
      {:noreply, state}
    else
      # Run heartbeat
      Logger.info("Heartbeat triggered for #{state.session_key}")
      run_heartbeat(state)
    end
  end

  # Reschedule next heartbeat after completion
  @impl true
  def handle_info(:heartbeat_done, state) do
    state = reschedule_heartbeat(state)
    {:noreply, state}
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

    # Monitor the restarted loop process
    Process.monitor(new_loop_pid)

    {:noreply, %{state | loop_pid: new_loop_pid}}
  end

  # Handle EXIT from linked AgentLoop when trap_exit is true
  def handle_info({:EXIT, pid, _reason}, %{loop_pid: pid} = state) do
    # The :DOWN monitor message will also fire and handle the restart
    {:noreply, state}
  end

  def handle_info({:EXIT, _pid, _reason}, state) do
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    # A2A auto-unregister on session shutdown
    if state.a2a_registered and state.agent_id do
      try do
        A2ARouter.unregister(state.agent_id)
        Logger.info("A2A: Unregistered agent #{state.agent_id} on session terminate")
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  # Private Functions

  # ============================================================================
  # Heartbeat
  # ============================================================================

  defp maybe_schedule_heartbeat(state, nil), do: state

  defp maybe_schedule_heartbeat(state, agent) do
    interval = get_heartbeat_interval(agent)

    if interval && interval > 0 do
      interval_ms = interval * 1000
      ref = Process.send_after(self(), :heartbeat, interval_ms)
      Logger.info("Heartbeat scheduled for #{state.session_key} every #{interval}s")
      %{state | heartbeat_ref: ref}
    else
      state
    end
  end

  defp reschedule_heartbeat(state) do
    agent = load_agent(state.agent_id)
    interval = get_heartbeat_interval(agent)

    if interval && interval > 0 do
      interval_ms = interval * 1000
      ref = Process.send_after(self(), :heartbeat, interval_ms)
      %{state | heartbeat_ref: ref}
    else
      state
    end
  end

  defp run_heartbeat(state) do
    # Build heartbeat prompt
    prompt = build_heartbeat_prompt(state)

    # Mark agent as running, run in background task
    worker_pid = self()
    session_key = state.session_key
    loop_pid = state.loop_pid

    state = %{state | agent_running: true}

    Task.start(fn ->
      result = safe_run_agent(loop_pid, prompt, [])

      case result do
        {:ok, response} ->
          if heartbeat_ok?(response) do
            Logger.debug("Heartbeat OK for #{session_key} — silent")
          else
            # Non-OK response: broadcast to channel for delivery
            Logger.info("Heartbeat alert for #{session_key}: #{String.slice(response, 0, 100)}")

            Phoenix.PubSub.broadcast(
              ClawdEx.PubSub,
              "session:#{session_key}",
              {:heartbeat_alert, response}
            )
          end

        {:error, reason} ->
          Logger.warning("Heartbeat failed for #{session_key}: #{inspect(reason)}")
      end

      send(worker_pid, :agent_finished)
      send(worker_pid, :heartbeat_done)
    end)

    {:noreply, state}
  end

  defp build_heartbeat_prompt(state) do
    workspace = state.config[:workspace]

    heartbeat_content =
      if workspace do
        path = Path.join(Path.expand(workspace), "HEARTBEAT.md")

        case File.read(path) do
          {:ok, content} when byte_size(content) > 0 ->
            "Read HEARTBEAT.md if it exists (workspace context). Follow it strictly. " <>
              "Do not infer or repeat old tasks from prior chats. " <>
              "If nothing needs attention, reply HEARTBEAT_OK.\n\n" <>
              "HEARTBEAT.md contents:\n#{content}"

          _ ->
            @default_heartbeat_prompt
        end
      else
        @default_heartbeat_prompt
      end

    heartbeat_content
  end

  defp heartbeat_ok?(response) do
    response
    |> String.trim()
    |> String.starts_with?("HEARTBEAT_OK")
  end

  defp get_heartbeat_interval(nil), do: nil

  defp get_heartbeat_interval(agent) do
    # Check agent schema field first (added by engineer #1),
    # then fall back to config map. Schema field defaults to 0,
    # so we check for a positive value explicitly.
    schema_val =
      if Map.has_key?(agent, :heartbeat_interval_seconds) do
        agent.heartbeat_interval_seconds
      end

    config_val =
      if is_map(agent.config) do
        agent.config["heartbeat_interval_seconds"]
      end

    cond do
      is_integer(schema_val) and schema_val > 0 -> schema_val
      is_integer(config_val) and config_val > 0 -> config_val
      true -> nil
    end
  end

  # ============================================================================
  # Always-On / Session Recovery
  # ============================================================================

  defp load_agent(nil), do: nil

  defp load_agent(agent_id) do
    Repo.get(ClawdEx.Agents.Agent, agent_id)
  rescue
    _ -> nil
  end

  # A2A auto-register: register agent with capabilities if present
  defp maybe_a2a_register(state, nil), do: state

  defp maybe_a2a_register(state, agent) do
    capabilities = Map.get(agent, :capabilities, [])

    if capabilities != [] and state.agent_id do
      try do
        :ok = A2ARouter.register(state.agent_id, capabilities)
        Logger.info("A2A: Auto-registered agent #{state.agent_id} with capabilities: #{inspect(capabilities)}")
        %{state | a2a_registered: true}
      rescue
        e ->
          Logger.warning("A2A: Failed to auto-register agent #{state.agent_id}: #{Exception.message(e)}")
          state
      catch
        :exit, reason ->
          Logger.warning("A2A: Failed to auto-register agent #{state.agent_id}: #{inspect(reason)}")
          state
      end
    else
      state
    end
  end

  @doc false
  def is_always_on?(nil), do: false

  def is_always_on?(agent) do
    # Check schema field first (engineer #1), then config map fallback
    schema_val =
      if Map.has_key?(agent, :always_on), do: agent.always_on, else: nil

    config_val =
      if is_map(agent.config), do: agent.config["always_on"], else: nil

    schema_val == true or config_val == true
  end

  defp maybe_recover_context(session, agent) do
    # Only recover if always_on and there are existing messages
    if is_always_on?(agent) do
      import Ecto.Query

      count =
        Message
        |> where([m], m.session_id == ^session.id)
        |> select([m], count(m.id))
        |> Repo.one()

      if count > 0 do
        Logger.info(
          "Always-on session #{session.session_key} recovering context " <>
            "(#{min(count, @recovery_message_count)} of #{count} messages)"
        )
      end
    end

    :ok
  rescue
    _ -> :ok
  end

  # ============================================================================
  # Registry / Helpers
  # ============================================================================

  defp via_tuple(session_key) do
    {:via, Registry, {ClawdEx.SessionRegistry, session_key}}
  end

  defp handle_reset_trigger(content, opts, state) do
    Logger.info("Manual reset triggered for session #{state.session_key}")

    # 重置会话
    case Repo.get(Session, state.session_id) do
      nil ->
        Logger.error("Session #{state.session_key} not found in DB for reset (id=#{state.session_id})")
        {:reply, {:error, "Session not found"}, state}

      session ->
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
  end

  defp restart_with_new_session(state, new_session) do
    # 停止旧的 Agent Loop
    if state.loop_pid && Process.alive?(state.loop_pid) do
      GenServer.stop(state.loop_pid, :normal, 5000)
    end

    # 启动新的 Agent Loop
    config = %{
      default_model: get_agent_model(new_session.agent_id),
      workspace: get_agent_workspace(new_session.agent_id),
      model_override: new_session.model_override
    }

    {:ok, new_loop_pid} =
      AgentLoop.start_link(
        session_id: new_session.id,
        agent_id: new_session.agent_id,
        config: config
      )

    # Monitor the new loop process
    Process.monitor(new_loop_pid)

    %{
      state
      | session_id: new_session.id,
        agent_id: new_session.agent_id,
        loop_pid: new_loop_pid,
        config: config
    }
  end

  # Apply model_override from session DB to the opts passed to AgentLoop.run
  # This ensures the loop uses the session's override model if set
  defp maybe_apply_model_override(session, opts) do
    case session.model_override do
      nil -> opts
      "" -> opts
      override -> Keyword.put_new(opts, :model, Models.resolve(override))
    end
  end

  defp update_last_activity(session_id) do
    case Repo.get(Session, session_id) do
      nil ->
        Logger.error("Cannot update last_activity: session #{session_id} not found")
        :ok

      session ->
        case session |> Session.changeset(%{last_activity_at: DateTime.utc_now()}) |> Repo.update() do
          {:ok, _} -> :ok
          {:error, changeset} ->
            Logger.error("Failed to update last_activity for session #{session_id}: #{inspect(changeset.errors)}")
            :ok
        end
    end
  end

  defp safe_update_last_activity(session_id) do
    update_last_activity(session_id)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp load_or_create_session(session_key, agent_id, channel) do
    # 先尝试查找已存在的 session
    case Repo.get_by(Session, session_key: session_key) do
      nil ->
        # 不存在，创建新的
        create_new_session(session_key, agent_id, channel)

      %{state: :archived} = session ->
        # 存在但已归档，重新激活它
        case session |> Session.changeset(%{state: :active}) |> Repo.update() do
          {:ok, updated} -> updated
          {:error, changeset} ->
            Logger.error("Failed to reactivate session #{session_key}: #{inspect(changeset.errors)}")
            # Return the archived session as fallback — still usable
            session
        end

      session ->
        # 存在且活跃，直接返回
        session
    end
  end

  defp create_new_session(session_key, agent_id, channel) do
    agent_id = agent_id || get_or_create_default_agent_id()

    case %Session{}
         |> Session.changeset(%{
           session_key: session_key,
           channel: channel,
           agent_id: agent_id
         })
         |> Repo.insert() do
      {:ok, session} ->
        session

      {:error, %Ecto.Changeset{errors: errors} = changeset} ->
        # Check if it's a unique constraint violation (race condition)
        if Keyword.has_key?(errors, :session_key) do
          case Repo.get_by(Session, session_key: session_key) do
            nil ->
              Logger.error("Session #{session_key} insert conflict but not found: #{inspect(errors)}")
              raise "Failed to create session #{session_key}"

            session ->
              session
          end
        else
          Logger.error("Failed to create session #{session_key}: #{inspect(changeset.errors)}")
          raise "Failed to create session #{session_key}: #{inspect(errors)}"
        end
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
        case %Agent{} |> Agent.changeset(%{name: "default"}) |> Repo.insert() do
          {:ok, agent} ->
            agent.id

          {:error, changeset} ->
            # Race condition: another process created it
            Logger.warning("Failed to create default agent: #{inspect(changeset.errors)}, retrying lookup")
            case Repo.get_by(Agent, name: "default") do
              nil ->
                Logger.error("Cannot create or find default agent")
                nil

              agent ->
                agent.id
            end
        end

      agent ->
        agent.id
    end
  end
end
