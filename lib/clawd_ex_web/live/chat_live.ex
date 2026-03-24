defmodule ClawdExWeb.ChatLive do
  @moduledoc """
  WebChat 实时聊天界面

  测试模式下不依赖 SessionManager，生产环境懒加载会话。
  """
  use ClawdExWeb, :live_view

  alias ClawdEx.Sessions.{SessionManager, SessionWorker}
  alias ClawdEx.Agents.Agent
  alias ClawdEx.Repo

  import ClawdExWeb.Helpers.SafeParse

  require Logger

  # ============================================================================
  # Lifecycle
  # ============================================================================

  @impl true
  def mount(params, session, socket) do
    # 加载可用的 agents
    agents = load_agents()

    # URL 参数中的 agent_id
    url_agent_id = safe_to_integer(params["agent_id"])

    # 检查是否需要显示 agent 选择器（新对话模式）
    show_agent_picker = params["new"] == "true" && is_nil(params["session"])

    # 优先使用 URL 参数中的 session key，否则从 session 中恢复
    # 如果是新对话模式，生成新的 session key
    session_key =
      cond do
        # 等待用户选择 agent
        show_agent_picker -> nil
        params["session"] -> params["session"]
        session["session_key"] -> session["session_key"]
        true -> find_or_create_session_key()
      end

    socket =
      socket
      |> assign(:session_key, session_key)
      |> assign(:agent_id, url_agent_id)
      |> assign(:agents, agents)
      |> assign(:show_agent_picker, show_agent_picker)
      |> assign(:messages, [])
      |> assign(:input, "")
      |> assign(:sending, false)
      |> assign(:streaming_content, nil)
      |> assign(:session_started, false)
      # 当前运行状态 {status, details}
      |> assign(:run_status, nil)
      # 工具执行历史 [{tool_name, status, result}]
      |> assign(:tool_executions, [])
      # 工具调用气泡是否展开
      |> assign(:tools_expanded, false)
      # 跟踪最后一条消息的 ID，用于重连后同步
      |> assign(:last_message_id, nil)

    # 在连接后再启动会话（避免测试时的问题）
    # 仅当有 session_key 时才初始化
    if connected?(socket) && session_key do
      send(self(), :init_session)
    end

    {:ok, socket}
  end

  defp load_agents do
    import Ecto.Query

    from(a in Agent,
      where: a.active == true,
      order_by: [asc: a.name]
    )
    |> Repo.all()
  end

  # ============================================================================
  # Events
  # ============================================================================

  @impl true
  def handle_event("send", %{"message" => message}, socket) when message != "" do
    # 确保会话已启动
    socket = maybe_start_session(socket)

    # 添加用户消息到界面
    user_message = %{
      id: System.unique_integer([:positive]),
      role: "user",
      content: message,
      timestamp: DateTime.utc_now()
    }

    socket =
      socket
      |> update(:messages, &(&1 ++ [user_message]))
      |> assign(:input, "")
      |> assign(:sending, true)
      |> assign(:streaming_content, "")
      # 新消息开始，清空工具历史
      |> assign(:tool_executions, [])

    # 异步发送消息
    send(self(), {:send_message, message})

    {:noreply, socket}
  end

  def handle_event("send", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("update_input", %{"message" => value}, socket) do
    {:noreply, assign(socket, :input, value)}
  end

  def handle_event("keydown", %{"key" => "Enter", "shiftKey" => false}, socket) do
    if socket.assigns.input != "" && !socket.assigns.sending do
      handle_event("send", %{"message" => socket.assigns.input}, socket)
    else
      {:noreply, socket}
    end
  end

  def handle_event("keydown", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("new_chat", _params, socket) do
    # 直接创建新会话
    new_session_key = generate_session_key()

    socket =
      socket
      |> assign(:show_agent_picker, false)
      |> assign(:session_key, new_session_key)
      |> assign(:agent_id, nil)
      |> assign(:messages, [])
      |> assign(:input, "")
      |> assign(:sending, false)
      |> assign(:streaming_content, nil)
      |> assign(:session_started, false)
      |> assign(:tool_executions, [])
      |> assign(:tools_expanded, false)

    {:noreply, socket}
  end

  def handle_event("select_agent", %{"agent_id" => agent_id}, socket) do
    # 用户选择了 agent，创建新会话
    agent_id = safe_to_integer(agent_id)
    new_session_key = generate_session_key()

    socket =
      socket
      |> assign(:show_agent_picker, false)
      |> assign(:session_key, new_session_key)
      |> assign(:agent_id, agent_id)
      |> assign(:messages, [])
      |> assign(:input, "")
      |> assign(:sending, false)
      |> assign(:streaming_content, nil)
      |> assign(:session_started, false)
      |> assign(:tool_executions, [])
      |> assign(:tools_expanded, false)

    # 延迟启动新会话
    send(self(), :init_session)

    {:noreply, socket}
  end

  def handle_event("toggle_tools_modal", _params, socket) do
    {:noreply, assign(socket, :tools_expanded, !socket.assigns.tools_expanded)}
  end

  def handle_event("close_tools_modal", _params, socket) do
    {:noreply, assign(socket, :tools_expanded, false)}
  end

  # 处理页面可见性变化 - 当用户切换回来时重新同步消息
  def handle_event("visibility_changed", %{"visible" => true}, socket) do
    # 用户切换回来了，重新同步消息
    Logger.debug("[ChatLive] User returned to page, syncing messages...")
    send(self(), :sync_messages)
    {:noreply, socket}
  end

  def handle_event("visibility_changed", %{"visible" => false}, socket) do
    # 用户离开了页面，记录当前状态以便后续恢复
    Logger.debug("[ChatLive] User left page")
    {:noreply, socket}
  end

  # ============================================================================
  # Info Handlers
  # ============================================================================

  @impl true
  def handle_info(:init_session, socket) do
    session_key = socket.assigns.session_key

    case start_session_safe(session_key) do
      :ok ->
        # 订阅会话事件（两个 topic：agent events 和 session results）
        if session_id = get_session_id(session_key) do
          Phoenix.PubSub.subscribe(ClawdEx.PubSub, "agent:#{session_id}")
        end

        # 订阅异步结果
        Phoenix.PubSub.subscribe(ClawdEx.PubSub, "session:#{session_key}")

        # 加载历史消息
        messages = load_messages(session_key)

        # 计算最后一条消息的 ID（用于后续同步）
        last_id = if messages != [], do: List.last(messages).id, else: nil

        socket =
          socket
          |> assign(:messages, messages)
          |> assign(:session_started, true)
          |> assign(:last_message_id, last_id)
          # 检查是否有正在进行的 agent 运行，恢复 sending 状态
          |> maybe_restore_sending_state()

        {:noreply, socket}

      {:error, reason} ->
        Logger.warning("Failed to start session: #{inspect(reason)}")
        {:noreply, assign(socket, :session_started, false)}
    end
  end

  # 处理页面可见性变化 - 当用户切换回来时重新同步
  def handle_info(:sync_messages, socket) do
    session_key = socket.assigns.session_key
    Logger.debug("[ChatLive] Syncing messages for session: #{session_key}")

    # 确保 PubSub 订阅仍然有效
    socket = ensure_subscriptions(socket)

    # 重新加载消息
    messages = load_messages(session_key)
    last_id = if messages != [], do: List.last(messages).id, else: nil

    # 计算新消息数量（用于调试）
    old_count = length(socket.assigns.messages)
    new_count = length(messages)

    if new_count > old_count do
      Logger.info("[ChatLive] Found #{new_count - old_count} new messages after sync")
    end

    socket =
      socket
      |> assign(:messages, messages)
      |> assign(:last_message_id, last_id)
      |> maybe_restore_sending_state()

    {:noreply, socket}
  end

  def handle_info({:send_message, content}, socket) do
    session_key = socket.assigns.session_key

    # 完全异步：使用 cast 发送消息，结果通过 PubSub 返回
    # 这样不会有任何超时问题
    SessionWorker.send_message_async(session_key, content)

    {:noreply, socket}
  end

  # 接收异步结果（通过 PubSub）
  def handle_info({:agent_result, result}, socket) do
    session_key = socket.assigns.session_key

    case result do
      {:ok, _response} ->
        # 先保存工具调用历史（如果有）
        socket = maybe_save_tools_as_message(socket)

        # 重要：重置 SessionWorker 的流式缓存
        SessionWorker.reset_streaming_cache(session_key)

        # 重新加载消息（包含刚保存的助手消息）
        # 不手动添加，避免重复
        messages = load_messages(session_key)

        socket =
          socket
          |> assign(:streaming_content, nil)
          |> assign(:sending, false)
          |> assign(:messages, messages)
          |> assign(:run_status, nil)
          |> assign(:tool_executions, [])
          |> assign(:tools_expanded, false)

        {:noreply, socket}

      {:error, reason} ->
        Logger.error("Failed to send message: #{inspect(reason)}")

        # 先保存工具调用历史（如果有）
        socket = maybe_save_tools_as_message(socket)

        # 如果有 streaming 内容，也保存它（可能是部分响应）
        socket = maybe_save_streaming_as_message(socket)

        # 重置 SessionWorker 的流式缓存
        SessionWorker.reset_streaming_cache(session_key)

        error_message = %{
          id: System.unique_integer([:positive]),
          role: "error",
          content: "发送失败: #{format_error(reason)}",
          timestamp: DateTime.utc_now()
        }

        socket =
          socket
          |> assign(:streaming_content, nil)
          |> update(:messages, &(&1 ++ [error_message]))
          |> assign(:sending, false)
          |> assign(:run_status, nil)
          |> assign(:tool_executions, [])
          |> assign(:tools_expanded, false)

        {:noreply, socket}
    end
  end

  # 处理流式响应
  # 从 SessionWorker 获取完整的累积内容，而不是自己累积 chunks
  # 这样可以避免页面切换后内容重复的问题
  def handle_info({:agent_chunk, _run_id, %{content: _content}}, socket) do
    if socket.assigns.sending do
      # 从 SessionWorker 获取完整的累积内容
      # SessionWorker 负责累积所有 chunks，ChatLive 只负责显示
      session_key = socket.assigns.session_key

      cached_content =
        try do
          case ClawdEx.Sessions.SessionWorker.get_state(session_key) do
            %{streaming_content: content} when is_binary(content) -> content
            _ -> socket.assigns.streaming_content || ""
          end
        rescue
          _ -> socket.assigns.streaming_content || ""
        catch
          :exit, _ -> socket.assigns.streaming_content || ""
        end

      {:noreply, assign(socket, :streaming_content, cached_content)}
    else
      # 忽略在 send_message 完成后到达的 chunks
      {:noreply, socket}
    end
  end

  # 处理运行状态更新
  def handle_info({:agent_status, _run_id, status, details}, socket) do
    if socket.assigns.sending do
      socket = handle_status_update(socket, status, details)
      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # 处理不同状态的更新
  defp handle_status_update(socket, :inferring, details) do
    # 新一轮推理开始
    # 1. 如果有工具调用历史，先保存为工具调用消息
    socket = maybe_save_tools_as_message(socket)
    # 2. 如果有未保存的 streaming 内容，保存为消息
    socket = maybe_save_streaming_as_message(socket)
    # 3. 重置工具执行状态
    socket
    |> assign(:tool_executions, [])
    |> assign(:tools_expanded, false)
    |> assign(:run_status, {:inferring, details})
  end

  defp handle_status_update(socket, :tools_start, %{tools: _tools, count: _count}) do
    # 多工具批量开始 - 不清空历史，让工具调用累积显示
    # 只有在新消息发送时或 run 结束时才清空
    socket
  end

  defp handle_status_update(socket, :tool_start, %{tool: tool_name} = details) do
    # 工具开始执行，添加到执行历史（包含参数摘要）
    params = Map.get(details, :params, %{})
    params_summary = summarize_params(params)

    execution = %{
      tool: tool_name,
      status: :running,
      params: params_summary,
      started_at: DateTime.utc_now()
    }

    socket
    |> update(:tool_executions, &(&1 ++ [execution]))
    |> assign(:run_status, {:tool_start, details})
  end

  defp handle_status_update(socket, :tool_done, %{tool: tool_name} = details) do
    # 工具执行完成，更新执行历史
    success = Map.get(details, :success, true)

    socket
    |> update(:tool_executions, fn execs ->
      # 找到最后一个匹配的 running 状态工具并更新
      {updated, _} =
        Enum.map_reduce(Enum.reverse(execs), false, fn exec, found ->
          if not found and exec.tool == tool_name and exec.status == :running do
            {%{exec | status: if(success, do: :done, else: :error)}, true}
          else
            {exec, found}
          end
        end)

      Enum.reverse(updated)
    end)
    |> assign(:run_status, {:tool_done, details})
  end

  defp handle_status_update(socket, status, details) do
    assign(socket, :run_status, {status, details})
  end

  # 如果有 streaming 内容，保存为消息
  defp maybe_save_streaming_as_message(socket) do
    content = socket.assigns.streaming_content

    if content && content != "" do
      message = %{
        id: System.unique_integer([:positive]),
        role: "assistant",
        content: content,
        timestamp: DateTime.utc_now()
      }

      # 通知 SessionWorker 重置流式缓存，避免重复内容
      session_key = socket.assigns.session_key
      SessionWorker.reset_streaming_cache(session_key)

      socket
      |> update(:messages, &(&1 ++ [message]))
      |> assign(:streaming_content, nil)
    else
      socket
    end
  end

  # 如果有工具执行历史，保存为工具调用消息
  defp maybe_save_tools_as_message(socket) do
    tools = socket.assigns.tool_executions

    if tools != [] do
      message = %{
        id: System.unique_integer([:positive]),
        role: "tools",
        content: tools,
        timestamp: DateTime.utc_now()
      }

      socket
      |> update(:messages, &(&1 ++ [message]))
      |> assign(:tool_executions, [])
    else
      socket
    end
  end

  # 简化工具参数用于显示
  defp summarize_params(params) when is_map(params) do
    # 提取关键参数显示
    cond do
      Map.has_key?(params, "command") ->
        cmd = params["command"] |> String.split("\n") |> hd() |> String.slice(0, 60)
        if String.length(params["command"]) > 60, do: cmd <> "...", else: cmd

      Map.has_key?(params, "path") ->
        Path.basename(params["path"])

      Map.has_key?(params, "url") ->
        URI.parse(params["url"]).host || params["url"]

      Map.has_key?(params, "query") ->
        "\"#{String.slice(params["query"], 0, 40)}#{if String.length(params["query"] || "") > 40, do: "...", else: ""}\""

      Map.has_key?(params, "action") ->
        params["action"]

      true ->
        keys = Map.keys(params) |> Enum.take(2) |> Enum.join(", ")
        if keys != "", do: "(#{keys})", else: nil
    end
  end

  defp summarize_params(_), do: nil

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp generate_session_key do
    "web:" <> (:crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower))
  end

  # 确保 PubSub 订阅仍然有效
  defp ensure_subscriptions(socket) do
    session_key = socket.assigns.session_key

    # 重新订阅（Phoenix.PubSub.subscribe 是幂等的）
    if session_id = get_session_id(session_key) do
      Phoenix.PubSub.subscribe(ClawdEx.PubSub, "agent:#{session_id}")
    end

    Phoenix.PubSub.subscribe(ClawdEx.PubSub, "session:#{session_key}")

    socket
  end

  # 检查 session 是否有正在进行的 agent 运行，恢复 sending 状态和 streaming_content
  defp maybe_restore_sending_state(socket) do
    session_key = socket.assigns.session_key

    try do
      case SessionWorker.get_state(session_key) do
        %{agent_running: true, streaming_content: cached_content}
        when is_binary(cached_content) and cached_content != "" ->
          # Agent 正在运行且有缓存内容，恢复完整的流式内容
          Logger.info(
            "[ChatLive] Restoring streaming state with #{String.length(cached_content)} chars from cache"
          )

          socket
          |> assign(:sending, true)
          |> assign(:streaming_content, cached_content)

        %{agent_running: true} ->
          # Agent 正在运行但没有缓存内容（刚开始或被清空）
          # 保持当前的 streaming_content（可能从 PubSub 接收了部分内容）
          Logger.debug("[ChatLive] Agent running but no cached content, keeping current state")
          current_streaming = socket.assigns.streaming_content

          socket
          |> assign(:sending, true)
          |> assign(:streaming_content, current_streaming || "")

        _ ->
          # 没有正在运行的 agent，确保 sending 为 false
          # 同时清空 streaming_content（因为响应已完成）
          Logger.debug("[ChatLive] Agent not running, clearing streaming state")

          socket
          |> assign(:sending, false)
          |> assign(:streaming_content, nil)
      end
    rescue
      e ->
        Logger.warning("[ChatLive] Error restoring state: #{inspect(e)}")
        socket
    catch
      :exit, reason ->
        Logger.warning("[ChatLive] Exit restoring state: #{inspect(reason)}")
        socket
    end
  end

  # 查找可复用的空 web session（消息数为 0），或创建新的
  defp find_or_create_session_key do
    import Ecto.Query

    # 查找消息数为 0 的活跃 web session
    case ClawdEx.Repo.one(
           from(s in ClawdEx.Sessions.Session,
             where: s.channel == "web" and s.state == :active and s.message_count == 0,
             order_by: [desc: s.updated_at],
             limit: 1,
             select: s.session_key
           )
         ) do
      nil ->
        # 没有空 session，创建新的
        generate_session_key()

      existing_key ->
        # 复用空 session
        existing_key
    end
  end

  defp start_session_safe(session_key) do
    try do
      case SessionManager.start_session(session_key: session_key, channel: "web") do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        error -> error
      end
    rescue
      _ -> {:error, :session_manager_unavailable}
    catch
      :exit, _ -> {:error, :session_manager_unavailable}
    end
  end

  defp maybe_start_session(socket) do
    if socket.assigns.session_started do
      socket
    else
      case start_session_safe(socket.assigns.session_key) do
        :ok -> assign(socket, :session_started, true)
        _ -> socket
      end
    end
  end

  defp get_session_id(session_key) do
    try do
      case SessionWorker.get_state(session_key) do
        %{session_id: id} -> id
        _ -> nil
      end
    rescue
      _ -> nil
    catch
      :exit, _ -> nil
    end
  end

  defp load_messages(session_key) do
    try do
      case SessionWorker.get_history(session_key, limit: 100) do
        messages when is_list(messages) ->
          Enum.map(messages, fn m ->
            role = m.role || m[:role]
            # 确保 role 是 string（数据库可能返回 atom）
            role_str = if is_atom(role), do: Atom.to_string(role), else: role

            %{
              id: System.unique_integer([:positive]),
              role: role_str,
              content: m.content || m[:content] || "",
              timestamp: m[:inserted_at] || m.inserted_at || DateTime.utc_now()
            }
          end)

        _ ->
          []
      end
    rescue
      e ->
        Logger.warning("Failed to load messages: #{inspect(e)}")
        []
    catch
      :exit, reason ->
        Logger.warning("Failed to load messages (exit): #{inspect(reason)}")
        []
    end
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error({:noproc, _}), do: "会话服务不可用"
  defp format_error(:noproc), do: "会话服务不可用"
  defp format_error(reason), do: inspect(reason)

  # ============================================================================
  # Components
  # ============================================================================

  @doc """
  工具调用气泡组件，用于显示历史工具调用记录
  """
  attr :tools, :list, required: true
  attr :collapsed, :boolean, default: true

  def tools_bubble(assigns) do
    ~H"""
    <div class="flex justify-start">
      <div class="max-w-[85%] rounded-2xl px-3 py-2 shadow-sm bg-gray-900/70 text-gray-400 border border-gray-700/50">
        <div class="text-xs text-gray-500 mb-1 font-medium flex items-center gap-1">
          <span>🔧</span>
          <span>工具调用 ({length(@tools)})</span>
        </div>
        <%= if @collapsed do %>
          <div class="text-xs text-gray-500">
            {Enum.map_join(@tools, ", ", fn t -> t.tool || t[:tool] || "unknown" end)}
          </div>
        <% else %>
          <div class="space-y-1">
            <%= for {exec, idx} <- Enum.with_index(@tools) do %>
              <div class={[
                "flex items-center gap-2 text-xs p-1.5 rounded",
                (exec.status || exec[:status]) == :done && "bg-green-900/20",
                (exec.status || exec[:status]) == :error && "bg-red-900/20",
                (exec.status || exec[:status]) not in [:done, :error] && "bg-gray-800/50"
              ]}>
                <span class="text-gray-600 w-3">{idx + 1}.</span>
                <%= case exec.status || exec[:status] do %>
                  <% :done -> %>
                    <span class="text-green-500">✓</span>
                  <% :error -> %>
                    <span class="text-red-500">✗</span>
                  <% _ -> %>
                    <span class="text-gray-500">○</span>
                <% end %>
                <span class="font-mono text-gray-400">{exec.tool || exec[:tool] || "unknown"}</span>
                <%= if exec[:params] || exec.params do %>
                  <span class="text-gray-600 truncate max-w-[200px]">
                    {exec[:params] || exec.params}
                  </span>
                <% end %>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end
