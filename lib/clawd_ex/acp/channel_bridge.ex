defmodule ClawdEx.ACP.ChannelBridge do
  @moduledoc """
  Bridges ACP runtime events to messaging channels (Telegram, Discord, WebChat).

  Handles event throttling/batching to prevent message floods:
  - text_delta events are accumulated and flushed periodically
  - tool_call events are shown as progress indicators
  - done/error events trigger final announcements

  All events are also broadcast via PubSub for any subscriber.
  """

  require Logger

  alias ClawdEx.ACP.Event

  @doc """
  Handle an ACP event from a session, forwarding to the appropriate channel.
  Called synchronously from the session GenServer — should be fast.
  """
  @spec handle_event(map(), Event.t()) :: :ok
  def handle_event(_session_state, %Event{type: :text_delta} = _event) do
    # Text deltas are accumulated by the Session GenServer.
    # The periodic flush or done event will send the accumulated text.
    # We broadcast via PubSub for real-time subscribers (WebSocket, SSE).
    :ok
  end

  def handle_event(session_state, %Event{type: :tool_call} = event) do
    label = session_state.label || session_state.agent_id
    tool_name = event.tool_title || event.tool_call_id || "unknown"
    message = "🔧 [#{label}] 正在执行: #{tool_name}"

    # Broadcast tool call event
    broadcast_channel_event(session_state, :tool_call, message)
    :ok
  end

  def handle_event(session_state, %Event{type: :status} = event) do
    label = session_state.label || session_state.agent_id
    message = "📡 [#{label}] #{event.text}"

    broadcast_channel_event(session_state, :status, message)
    :ok
  end

  def handle_event(_session_state, %Event{type: :done} = _event) do
    # Completion is handled by announce_completion/3
    :ok
  end

  def handle_event(session_state, %Event{type: :error} = event) do
    label = session_state.label || session_state.agent_id
    error_text = event.text || event.code || "unknown error"
    message = "❌ ACP session [#{label}] 错误: #{error_text}"

    send_to_channel(session_state, message)
    :ok
  end

  def handle_event(_session_state, _event), do: :ok

  @doc """
  Announce task completion to the originating channel.
  """
  @spec announce_completion(map(), {:ok, term()} | {:error, term()}, non_neg_integer()) :: :ok
  def announce_completion(session_state, result, duration_ms) do
    label = session_state.label || session_state.agent_id
    duration_str = format_duration(duration_ms)

    message =
      case result do
        {:ok, content} when is_binary(content) and content != "" ->
          summary = truncate(content, 2000)
          "✅ ACP session [#{label}] 完成 (#{duration_str})\n---\n#{summary}"

        {:ok, _} ->
          "✅ ACP session [#{label}] 完成 (#{duration_str})"

        {:error, :timeout} ->
          "⚠️ ACP session [#{label}] 超时 (#{duration_str})"

        {:error, reason} ->
          "❌ ACP session [#{label}] 失败 (#{duration_str})\n---\n错误: #{inspect(reason)}"
      end

    send_to_channel(session_state, message)
    :ok
  end

  # --- Private ---

  defp send_to_channel(%{channel: nil}, _message), do: :ok
  defp send_to_channel(%{channel_to: nil}, _message), do: :ok

  defp send_to_channel(session_state, message) do
    channel = session_state.channel
    to = session_state.channel_to

    result =
      case channel do
        "telegram" ->
          topic_id = extract_topic_id(session_state.parent_session_key)
          opts = if topic_id, do: [message_thread_id: topic_id], else: []
          ClawdEx.Channels.Telegram.send_message(to, message, opts)

        "discord" ->
          ClawdEx.Channels.Discord.send_message(to, message)

        _ ->
          Logger.debug("[ChannelBridge] Unknown channel: #{channel}")
          :ok
      end

    case result do
      {:error, reason} ->
        Logger.warning("[ChannelBridge] Failed to send to #{channel}: #{inspect(reason)}")

      _ ->
        :ok
    end

    :ok
  end

  defp broadcast_channel_event(session_state, event_type, message) do
    if session_state.parent_session_key do
      Phoenix.PubSub.broadcast(
        ClawdEx.PubSub,
        "session:#{session_state.parent_session_key}",
        {:acp_channel_event, %{
          session_key: session_state.session_key,
          type: event_type,
          message: message
        }}
      )
    end
  end

  defp extract_topic_id(nil), do: nil

  defp extract_topic_id(session_key) when is_binary(session_key) do
    case Regex.run(~r/:topic:(\d+)/, session_key) do
      [_, topic_id] -> topic_id
      _ -> nil
    end
  end

  defp extract_topic_id(_), do: nil

  defp format_duration(ms) when ms < 1000, do: "#{ms}ms"
  defp format_duration(ms) when ms < 60_000, do: "#{Float.round(ms / 1000, 1)}s"
  defp format_duration(ms), do: "#{Float.round(ms / 60_000, 1)}m"

  defp truncate(str, max) when is_binary(str) do
    if String.length(str) > max do
      String.slice(str, 0, max - 3) <> "..."
    else
      str
    end
  end

  defp truncate(other, _max), do: inspect(other)
end
