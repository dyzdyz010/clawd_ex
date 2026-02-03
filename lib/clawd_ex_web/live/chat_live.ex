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
  def mount(params, session, socket) do
    # 优先使用 URL 参数中的 session key，否则从 session 中恢复，最后生成新的
    session_key = params["session"] || session["session_key"] || generate_session_key()

    socket =
      socket
      |> assign(:session_key, session_key)
      |> assign(:messages, [])
      |> assign(:input, "")
      |> assign(:sending, false)
      |> assign(:streaming_content, nil)
      |> assign(:session_started, false)
      # 当前运行状态 {status, details}
      |> assign(:run_status, nil)
      # 工具执行历史 [{tool_name, status, result}]
      |> assign(:tool_executions, [])

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
        # 订阅会话事件（两个 topic：agent events 和 session results）
        if session_id = get_session_id(session_key) do
          Phoenix.PubSub.subscribe(ClawdEx.PubSub, "agent:#{session_id}")
        end

        # 订阅异步结果
        Phoenix.PubSub.subscribe(ClawdEx.PubSub, "session:#{session_key}")

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

    # 完全异步：使用 cast 发送消息，结果通过 PubSub 返回
    # 这样不会有任何超时问题
    SessionWorker.send_message_async(session_key, content)

    {:noreply, socket}
  end

  # 接收异步结果（通过 PubSub）
  def handle_info({:agent_result, result}, socket) do
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

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # 处理不同状态的更新
  defp handle_status_update(socket, :inferring, details) do
    # 新一轮推理开始，如果有未保存的 streaming 内容，先保存为消息
    socket = maybe_save_streaming_as_message(socket)
    assign(socket, :run_status, {:inferring, details})
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

      socket
      |> update(:messages, &(&1 ++ [message]))
      |> assign(:streaming_content, nil)
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
end
