defmodule ClawdExWeb.Api.SessionController do
  @moduledoc """
  Session CRUD and messaging REST API controller.
  """
  use ClawdExWeb, :controller

  alias ClawdEx.Sessions.{SessionManager, SessionWorker}

  action_fallback ClawdExWeb.Api.FallbackController

  @doc """
  GET /api/v1/sessions — List all active sessions
  """
  def index(conn, _params) do
    session_keys = SessionManager.list_sessions()

    sessions =
      Enum.map(session_keys, fn key ->
        case get_session_state(key) do
          {:ok, state} -> format_session(key, state)
          _ -> format_session_minimal(key)
        end
      end)

    json(conn, %{data: sessions, total: length(sessions)})
  end

  @doc """
  GET /api/v1/sessions/:key — Get session details
  """
  def show(conn, %{"key" => key}) do
    decoded_key = URI.decode(key)

    case SessionManager.find_session(decoded_key) do
      {:ok, _pid} ->
        case get_session_state(decoded_key) do
          {:ok, state} ->
            json(conn, %{data: format_session_detail(decoded_key, state)})

          {:error, reason} ->
            json(conn, %{data: format_session_minimal(decoded_key), warning: inspect(reason)})
        end

      :not_found ->
        {:error, :not_found}
    end
  end

  @doc """
  POST /api/v1/sessions/:key/messages — Send a message to a session
  """
  def send_message(conn, %{"key" => key} = params) do
    decoded_key = URI.decode(key)
    content = params["content"] || params["message"] || ""

    if content == "" do
      {:error, :bad_request, "Message content is required"}
    else
      # Ensure session exists
      case SessionManager.find_session(decoded_key) do
        {:ok, _pid} ->
          do_send_message(conn, decoded_key, content)

        :not_found ->
          {:error, :not_found}
      end
    end
  end

  @doc """
  DELETE /api/v1/sessions/:key — Delete/stop a session
  """
  def delete(conn, %{"key" => key}) do
    decoded_key = URI.decode(key)

    case SessionManager.stop_session(decoded_key) do
      :ok ->
        json(conn, %{status: "deleted", session_key: decoded_key})

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  # Private helpers

  defp do_send_message(conn, session_key, content) do
    # Use async send to avoid blocking the HTTP request for long LLM calls
    # The client should use WebSocket for real-time streaming
    try do
      SessionWorker.send_message_async(session_key, content)

      conn
      |> put_status(202)
      |> json(%{
        status: "accepted",
        session_key: session_key,
        message: "Message queued for processing. Use WebSocket for real-time streaming."
      })
    rescue
      e ->
        {:error, Exception.message(e)}
    end
  end

  defp get_session_state(key) do
    try do
      {:ok, SessionWorker.get_state(key)}
    rescue
      _ -> {:error, :unavailable}
    catch
      :exit, _ -> {:error, :unavailable}
    end
  end

  defp format_session(key, state) do
    %{
      session_key: key,
      agent_id: Map.get(state, :agent_id),
      channel: Map.get(state, :channel),
      agent_running: Map.get(state, :agent_running, false)
    }
  end

  defp format_session_minimal(key) do
    %{
      session_key: key,
      agent_id: nil,
      channel: nil,
      agent_running: false
    }
  end

  defp format_session_detail(key, state) do
    %{
      session_key: key,
      session_id: Map.get(state, :session_id),
      agent_id: Map.get(state, :agent_id),
      channel: Map.get(state, :channel),
      agent_running: Map.get(state, :agent_running, false),
      config: Map.get(state, :config, %{})
    }
  end
end
