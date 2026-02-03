defmodule ClawdExWeb.ChatLive do
  @moduledoc """
  WebChat 实时聊天界面

  测试模式下不依赖 SessionManager，生产环境懒加载会话。
  """
  use ClawdExWeb, :live_view

  alias ClawdEx.Sessions.{SessionManager, SessionWorker}

  require Logger

  # ============================================================================
  # Lifecycle
  # ============================================================================

  @impl true
  def mount(_params, session, socket) do
    # 生成或恢复会话 key
    session_key = session["session_key"] || generate_session_key()

    socket =
      socket
      |> assign(:session_key, session_key)
      |> assign(:messages, [])
      |> assign(:input, "")
      |> assign(:sending, false)
      |> assign(:streaming_content, nil)
      |> assign(:session_started, false)
      |> assign(:run_status, nil)  # 当前运行状态 {status, details}
      |> assign(:tool_executions, [])  # 工具执行历史 [{tool_name, status, result}]

    # 在连接后再启动会话（避免测试时的问题）
    if connected?(socket) do
      send(self(), :init_session)
    end

    {:ok, socket}
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
    # 创建新会话
    new_session_key = generate_session_key()

    socket =
      socket
      |> assign(:session_key, new_session_key)
      |> assign(:messages, [])
      |> assign(:input, "")
      |> assign(:sending, false)
      |> assign(:streaming_content, nil)
      |> assign(:session_started, false)

    # 延迟启动新会话
    send(self(), :init_session)

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
        # 订阅会话事件
        if session_id = get_session_id(session_key) do
          Phoenix.PubSub.subscribe(ClawdEx.PubSub, "agent:#{session_id}")
        end

        # 加载历史消息
        messages = load_messages(session_key)

        socket =
          socket
          |> assign(:messages, messages)
          |> assign(:session_started, true)

        {:noreply, socket}

      {:error, reason} ->
        Logger.warning("Failed to start session: #{inspect(reason)}")
        {:noreply, assign(socket, :session_started, false)}
    end
  end

  def handle_info({:send_message, content}, socket) do
    session_key = socket.assigns.session_key
    lv_pid = self()

    # 异步执行，避免阻塞 LiveView 进程（否则心跳超时会断开连接）
    Task.start(fn ->
      result =
        try do
          SessionWorker.send_message(session_key, content)
        rescue
          e -> {:error, Exception.message(e)}
        catch
          :exit, reason -> {:error, reason}
        end

      send(lv_pid, {:message_result, result})
    end)

    {:noreply, socket}
  end

  def handle_info({:message_result, result}, socket) do
    case result do
      {:ok, response} ->
        # 优先使用 streaming_content（如果有的话），否则用最终 response
        # 这样避免重复显示
        streaming = socket.assigns.streaming_content
        final_content = if streaming && streaming != "", do: streaming, else: response

        assistant_message = %{
          id: System.unique_integer([:positive]),
          role: "assistant",
          content: final_content,
          timestamp: DateTime.utc_now()
        }

        socket =
          socket
          |> update(:messages, &(&1 ++ [assistant_message]))
          |> assign(:sending, false)
          |> assign(:streaming_content, nil)
          |> assign(:run_status, nil)
          |> assign(:tool_executions, [])

        {:noreply, socket}

      {:error, reason} ->
        Logger.error("Failed to send message: #{inspect(reason)}")

        # 如果有 streaming 内容，也保存它（可能是部分响应）
        socket = maybe_save_streaming_as_message(socket)

        error_message = %{
          id: System.unique_integer([:positive]),
          role: "error",
          content: "发送失败: #{format_error(reason)}",
          timestamp: DateTime.utc_now()
        }

        socket =
          socket
          |> update(:messages, &(&1 ++ [error_message]))
          |> assign(:sending, false)
          |> assign(:streaming_content, nil)
          |> assign(:run_status, nil)
          |> assign(:tool_executions, [])

        {:noreply, socket}
    end
  end

  # 处理流式响应
  # 只在 sending 状态时处理 chunks，避免与同步响应竞态
  def handle_info({:agent_chunk, _run_id, %{content: content}}, socket) do
    if socket.assigns.sending do
      current = socket.assigns.streaming_content || ""
      {:noreply, assign(socket, :streaming_content, current <> content)}
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

  # 处理不同状态的更新
  defp handle_status_update(socket, :inferring, details) do
    # 新一轮推理开始，如果有未保存的 streaming 内容，先保存为消息
    socket = maybe_save_streaming_as_message(socket)
    assign(socket, :run_status, {:inferring, details})
  end

  defp handle_status_update(socket, :tool_start, %{tool: tool_name} = details) do
    # 工具开始执行，添加到执行历史
    execution = %{tool: tool_name, status: :running, started_at: DateTime.utc_now()}
    socket
    |> update(:tool_executions, &(&1 ++ [execution]))
    |> assign(:run_status, {:tool_start, details})
  end

  defp handle_status_update(socket, :tool_done, %{tool: tool_name, result: result} = details) do
    # 工具执行完成，更新执行历史
    socket
    |> update(:tool_executions, fn execs ->
      Enum.map(execs, fn exec ->
        if exec.tool == tool_name and exec.status == :running do
          %{exec | status: :done, result: summarize_result(result)}
        else
          exec
        end
      end)
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
      socket
      |> update(:messages, &(&1 ++ [message]))
      |> assign(:streaming_content, nil)
    else
      socket
    end
  end

  # 简化工具结果用于显示
  defp summarize_result(result) when is_binary(result) do
    if String.length(result) > 100 do
      String.slice(result, 0, 100) <> "..."
    else
      result
    end
  end
  defp summarize_result(result), do: inspect(result, limit: 3)

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp generate_session_key do
    "web:" <> (:crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower))
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
      case SessionWorker.get_history(session_key, limit: 50) do
        messages when is_list(messages) ->
          Enum.map(messages, fn m ->
            %{
              id: System.unique_integer([:positive]),
              role: m.role || m[:role],
              content: m.content || m[:content],
              timestamp: m[:inserted_at] || DateTime.utc_now()
            }
          end)

        _ ->
          []
      end
    rescue
      _ -> []
    catch
      :exit, _ -> []
    end
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error({:noproc, _}), do: "会话服务不可用"
  defp format_error(:noproc), do: "会话服务不可用"
  defp format_error(reason), do: inspect(reason)
  
  # 格式化运行状态显示
  defp format_status({:started, _details}), do: "正在准备..."
  defp format_status({:inferring, %{iteration: 0}}), do: "正在思考..."
  defp format_status({:inferring, %{iteration: n}}), do: "正在思考... (第 #{n + 1} 轮)"
  defp format_status({:tools_start, %{tools: tools}}), do: "准备执行: #{Enum.join(tools, ", ")}"
  defp format_status({:tool_start, %{tool: tool}}), do: "正在执行: #{tool}"
  defp format_status({:tool_done, %{tool: tool, success: true}}), do: "#{tool} 完成 ✓"
  defp format_status({:tool_done, %{tool: tool, success: false}}), do: "#{tool} 失败 ✗"
  defp format_status({:done, _}), do: "完成"
  defp format_status({:error, %{reason: reason}}), do: "错误: #{reason}"
  defp format_status({status, _}), do: "#{status}"
  defp format_status(nil), do: ""
end
