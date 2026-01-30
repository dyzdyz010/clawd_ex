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

    result =
      try do
        SessionWorker.send_message(session_key, content)
      rescue
        e -> {:error, Exception.message(e)}
      catch
        :exit, reason -> {:error, reason}
      end

    case result do
      {:ok, response} ->
        assistant_message = %{
          id: System.unique_integer([:positive]),
          role: "assistant",
          content: response,
          timestamp: DateTime.utc_now()
        }

        socket =
          socket
          |> update(:messages, &(&1 ++ [assistant_message]))
          |> assign(:sending, false)
          |> assign(:streaming_content, nil)

        {:noreply, socket}

      {:error, reason} ->
        Logger.error("Failed to send message: #{inspect(reason)}")

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

        {:noreply, socket}
    end
  end

  # 处理流式响应
  def handle_info({:agent_chunk, _run_id, %{content: content}}, socket) do
    current = socket.assigns.streaming_content || ""
    {:noreply, assign(socket, :streaming_content, current <> content)}
  end

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
end
