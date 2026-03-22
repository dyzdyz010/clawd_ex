defmodule ClawdExWeb.Api.StreamController do
  @moduledoc """
  SSE (Server-Sent Events) streaming controller.

  Provides HTTP-based streaming endpoints for agent responses:
  - GET /api/v1/sessions/:key/stream — SSE connection for live agent events
  - POST /api/v1/sessions/:key/chat — Send a message and stream the reply via SSE

  Uses standard HTTP chunked transfer encoding with `Plug.Conn.chunk/2`.
  No third-party SSE libraries required.

  ## Event Types

  - `message_start`  — Agent started generating a response
  - `message_delta`  — Incremental text chunk
  - `message_done`   — Agent finished generating
  - `message_error`  — Error during generation
  - `message_segment` — Complete text segment (before tool calls)
  - `keepalive`      — Heartbeat comment (every 15s)

  ## Reconnection

  Supports `Last-Event-ID` header for reconnection. Events include
  sequential IDs that clients can use to resume after disconnection.
  """
  use ClawdExWeb, :controller

  alias ClawdEx.Sessions.{SessionManager, SessionWorker}

  require Logger

  @keepalive_interval_ms 15_000

  @doc """
  GET /api/v1/sessions/:key/stream

  Opens an SSE connection. Subscribes to the agent's PubSub topic
  and relays events as SSE to the client.
  """
  def stream(conn, %{"key" => key}) do
    decoded_key = URI.decode(key)

    case SessionManager.find_session(decoded_key) do
      {:ok, _pid} ->
        start_sse_stream(conn, decoded_key)

      :not_found ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "not_found", message: "Session not found"}})
    end
  end

  @doc """
  POST /api/v1/sessions/:key/chat

  Sends a message to the session and streams the agent's response via SSE.
  """
  def chat(conn, %{"key" => key} = params) do
    decoded_key = URI.decode(key)
    content = params["content"] || params["message"] || ""

    if content == "" do
      conn
      |> put_status(:bad_request)
      |> json(%{error: %{code: "bad_request", message: "Message content is required"}})
    else
      case SessionManager.find_session(decoded_key) do
        {:ok, _pid} ->
          # Send the message async, then stream the response
          SessionWorker.send_message_async(decoded_key, content)
          start_sse_stream(conn, decoded_key)

        :not_found ->
          conn
          |> put_status(:not_found)
          |> json(%{error: %{code: "not_found", message: "Session not found"}})
      end
    end
  end

  # ===========================================================================
  # SSE Implementation
  # ===========================================================================

  defp start_sse_stream(conn, session_key) do
    # Get session_id for PubSub subscription
    session_id =
      try do
        state = SessionWorker.get_state(session_key)
        state.session_id
      rescue
        _ -> nil
      catch
        :exit, _ -> nil
      end

    if is_nil(session_id) do
      conn
      |> put_status(:service_unavailable)
      |> json(%{error: %{code: "unavailable", message: "Session state unavailable"}})
    else
      # Parse Last-Event-ID for reconnection support
      last_event_id = parse_last_event_id(conn)

      # Subscribe to agent PubSub topic
      Phoenix.PubSub.subscribe(ClawdEx.PubSub, "agent:#{session_id}")

      # Set SSE headers and start chunked response
      conn =
        conn
        |> put_resp_header("content-type", "text/event-stream")
        |> put_resp_header("cache-control", "no-cache")
        |> put_resp_header("connection", "keep-alive")
        |> put_resp_header("x-accel-buffering", "no")
        |> send_chunked(200)

      # Send initial connection event
      event_id = if last_event_id, do: last_event_id + 1, else: 1

      conn =
        send_sse_event(conn, "connected", %{
          session_key: session_key,
          session_id: session_id,
          reconnected: last_event_id != nil
        }, event_id)

      # Schedule first keepalive
      keepalive_ref = schedule_keepalive()

      # Enter the SSE event loop
      sse_loop(conn, session_id, event_id + 1, keepalive_ref)
    end
  end

  defp sse_loop(conn, session_id, event_id, keepalive_ref) do
    receive do
      # Agent started generating
      {:agent_status, _run_id, :started, details} ->
        conn = send_sse_event(conn, "message_start", %{
          role: "assistant",
          model: details[:model],
          started_at: details[:started_at]
        }, event_id)

        sse_loop(conn, session_id, event_id + 1, keepalive_ref)

      # Streaming text chunk
      {:agent_chunk, _run_id, chunk} ->
        conn = send_sse_event(conn, "message_delta", chunk, event_id)
        sse_loop(conn, session_id, event_id + 1, keepalive_ref)

      # Agent finished
      {:agent_status, _run_id, :done, details} ->
        conn = send_sse_event(conn, "message_done", %{
          content_preview: details[:content_preview]
        }, event_id)

        # Clean up and close connection after done
        cleanup(session_id, keepalive_ref)
        conn

      # Agent error
      {:agent_status, _run_id, :error, details} ->
        conn = send_sse_event(conn, "message_error", %{
          reason: details[:reason] || "unknown_error"
        }, event_id)

        cleanup(session_id, keepalive_ref)
        conn

      # Text segment (before tool calls)
      {:agent_segment, _run_id, content, meta} ->
        conn = send_sse_event(conn, "message_segment", %{
          content: content,
          continuing: meta[:continuing] || false
        }, event_id)

        sse_loop(conn, session_id, event_id + 1, keepalive_ref)

      # Inferring status (new inference round)
      {:agent_status, _run_id, :inferring, details} ->
        conn = send_sse_event(conn, "message_inferring", %{
          iteration: details[:iteration]
        }, event_id)

        sse_loop(conn, session_id, event_id + 1, keepalive_ref)

      # Tools done
      {:agent_status, _run_id, :tools_done, details} ->
        conn = send_sse_event(conn, "message_tools_done", %{
          tools: details[:tools],
          count: details[:count]
        }, event_id)

        sse_loop(conn, session_id, event_id + 1, keepalive_ref)

      # Other agent statuses — relay as generic status
      {:agent_status, _run_id, status, details} ->
        conn = send_sse_event(conn, "message_status", %{
          status: status,
          details: details
        }, event_id)

        sse_loop(conn, session_id, event_id + 1, keepalive_ref)

      # Keepalive heartbeat
      :keepalive ->
        case send_sse_comment(conn, "keepalive") do
          {:ok, conn} ->
            keepalive_ref = schedule_keepalive()
            sse_loop(conn, session_id, event_id, keepalive_ref)

          {:error, _reason} ->
            # Client disconnected
            cleanup(session_id, keepalive_ref)
            conn
        end

      # Session result (from async send)
      {:agent_result, _result} ->
        # The result is also broadcast, we just pass through
        sse_loop(conn, session_id, event_id, keepalive_ref)

      # Unknown message — skip
      _other ->
        sse_loop(conn, session_id, event_id, keepalive_ref)
    after
      # Timeout after 5 minutes of no events
      300_000 ->
        send_sse_event(conn, "timeout", %{
          message: "No events for 5 minutes, closing connection"
        }, event_id)

        cleanup(session_id, keepalive_ref)
        conn
    end
  end

  # ===========================================================================
  # SSE Formatting
  # ===========================================================================

  defp send_sse_event(conn, event_type, data, event_id) do
    payload = encode_data(data)

    sse_text = "id: #{event_id}\nevent: #{event_type}\ndata: #{payload}\n\n"

    case Plug.Conn.chunk(conn, sse_text) do
      {:ok, conn} -> conn
      {:error, _reason} -> conn
    end
  end

  defp send_sse_comment(conn, comment) do
    Plug.Conn.chunk(conn, ": #{comment}\n\n")
  end

  defp encode_data(data) when is_map(data) do
    Jason.encode!(data)
  end

  defp encode_data(%{content: _} = chunk) do
    Jason.encode!(Map.from_struct(chunk))
  rescue
    _ -> Jason.encode!(%{content: inspect(chunk)})
  end

  defp encode_data(data) when is_binary(data) do
    Jason.encode!(%{content: data})
  end

  defp encode_data(data) do
    Jason.encode!(%{data: inspect(data)})
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp parse_last_event_id(conn) do
    case get_req_header(conn, "last-event-id") do
      [id | _] ->
        case Integer.parse(id) do
          {n, _} -> n
          :error -> nil
        end

      [] ->
        nil
    end
  end

  defp schedule_keepalive do
    Process.send_after(self(), :keepalive, @keepalive_interval_ms)
  end

  defp cleanup(session_id, keepalive_ref) do
    Phoenix.PubSub.unsubscribe(ClawdEx.PubSub, "agent:#{session_id}")

    if is_reference(keepalive_ref) do
      Process.cancel_timer(keepalive_ref)
    end
  end
end
