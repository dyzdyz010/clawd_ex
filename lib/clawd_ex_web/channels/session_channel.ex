defmodule ClawdExWeb.Channels.SessionChannel do
  @moduledoc """
  Session 实时消息推送 Channel。

  Topic: "session:<session_key>"

  客户端 → 服务端:
    - "message"   — 向 session 发送用户消息
    - "typing"    — 广播 typing indicator
    - "subscribe" — 开始接收 session 的流式输出

  服务端 → 客户端:
    - "new_message"       — agent 完成的回复
    - "message:delta"     — 流式增量文本
    - "message:start"     — 开始生成
    - "message:complete"  — 生成完成
    - "message:error"     — 生成出错
    - "message:segment"   — 文本片段
    - "typing"            — 他人正在输入

  权限: 需要 gateway 类型认证（node 类型无法加入 session channel）
  """
  use Phoenix.Channel

  alias ClawdEx.Sessions.SessionManager
  alias ClawdEx.Sessions.SessionWorker

  require Logger

  @impl true
  def join("session:" <> session_key, _params, socket) do
    auth = socket.assigns[:auth]

    case auth do
      %{type: :gateway} ->
        case SessionManager.find_session(session_key) do
          {:ok, _pid} ->
            socket = assign(socket, :session_key, session_key)
            send(self(), :after_join)
            {:ok, socket}

          :not_found ->
            {:error, %{reason: "session_not_found"}}
        end

      _ ->
        {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def handle_info(:after_join, socket) do
    session_key = socket.assigns.session_key

    # Look up the session_id from the worker to subscribe to agent PubSub
    case SessionManager.find_session(session_key) do
      {:ok, _pid} ->
        try do
          state = SessionWorker.get_state(session_key)
          session_id = state.session_id

          socket = assign(socket, :session_id, session_id)
          Phoenix.PubSub.subscribe(ClawdEx.PubSub, "agent:#{session_id}")
          {:noreply, socket}
        catch
          kind, reason when kind in [:exit, :error] ->
            Logger.warning(
              "SessionChannel: failed to get state for #{session_key}: #{inspect(reason)}"
            )

            {:noreply, socket}
        end

      :not_found ->
        {:noreply, socket}
    end
  end

  # PubSub: agent run done → push "new_message"
  def handle_info({:agent_status, _run_id, :done, details}, socket) do
    push(socket, "new_message", %{
      role: "assistant",
      content: details[:content_preview] || ""
    })

    {:noreply, socket}
  end

  # PubSub: agent streaming chunk → push "message:delta"
  def handle_info({:agent_chunk, _run_id, chunk}, socket) do
    push(socket, "message:delta", %{delta: chunk})
    {:noreply, socket}
  end

  # PubSub: agent status started → push "message:start"
  def handle_info({:agent_status, _run_id, :started, details}, socket) do
    push(socket, "message:start", %{
      role: "assistant",
      model: details[:model]
    })

    {:noreply, socket}
  end

  # PubSub: agent status error → push "message:error"
  def handle_info({:agent_status, _run_id, :error, details}, socket) do
    push(socket, "message:error", %{
      error: details[:reason] || "unknown_error"
    })

    {:noreply, socket}
  end

  # PubSub: agent segment → push "message:segment"
  def handle_info({:agent_segment, _run_id, content, _meta}, socket) do
    push(socket, "message:segment", %{content: content})
    {:noreply, socket}
  end

  # Catch-all for other PubSub messages we don't care about
  def handle_info({:agent_status, _run_id, _status, _details}, socket) do
    {:noreply, socket}
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_in("message", %{"content" => content}, socket) do
    session_key = socket.assigns.session_key

    # Fire-and-forget: agent reply comes back via PubSub → "new_message"
    SessionWorker.send_message_async(session_key, content)

    {:reply, :ok, socket}
  end

  def handle_in("typing", payload, socket) do
    user_id = get_in(socket.assigns, [:auth, :user_id]) || "unknown"

    # Broadcast typing indicator to all other clients on this topic
    broadcast_from!(socket, "typing", %{
      user_id: user_id,
      is_typing: Map.get(payload, "is_typing", true)
    })

    {:noreply, socket}
  end

  def handle_in("subscribe", _payload, socket) do
    # Client explicitly wants to receive streaming output.
    # We already subscribed in after_join, so just acknowledge.
    {:reply, :ok, socket}
  end
end
