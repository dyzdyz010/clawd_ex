defmodule ClawdEx.Tools.SessionsSend do
  @moduledoc """
  发送消息到另一个会话

  这个工具允许一个会话向另一个会话发送消息，并同步等待响应。
  主要用于子代理与主代理之间的通信。
  """
  @behaviour ClawdEx.Tools.Tool

  alias ClawdEx.Sessions.SessionManager
  alias ClawdEx.Sessions.SessionWorker

  require Logger

  @default_timeout_seconds 30
  @max_timeout_seconds 300

  @impl true
  def name, do: "sessions_send"

  @impl true
  def description do
    """
    Send a message to another session and wait for a response.

    Use this to communicate with other sessions (e.g., parent agent, subagents).
    The message will be delivered to the target session as if it came from
    the sending session, and you'll receive their response.
    """
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        sessionKey: %{
          type: "string",
          description: "The session key of the target session to send the message to"
        },
        message: %{
          type: "string",
          description: "The message content to send to the target session"
        },
        timeoutSeconds: %{
          type: "integer",
          description:
            "How long to wait for a response (default: #{@default_timeout_seconds}, max: #{@max_timeout_seconds})"
        }
      },
      required: ["sessionKey", "message"]
    }
  end

  @impl true
  def execute(params, context) do
    session_key = get_param(params, :sessionKey)
    message = get_param(params, :message)
    timeout_seconds = get_timeout(params)

    sender_session_key = context[:session_key] || "unknown"

    cond do
      is_nil(session_key) or session_key == "" ->
        {:error, "sessionKey is required"}

      is_nil(message) or message == "" ->
        {:error, "message is required"}

      session_key == sender_session_key ->
        {:error, "Cannot send message to self"}

      true ->
        send_to_session(session_key, message, sender_session_key, timeout_seconds)
    end
  end

  defp send_to_session(session_key, message, sender_session_key, timeout_seconds) do
    case SessionManager.find_session(session_key) do
      {:ok, _pid} ->
        # 构造带来源信息的消息
        formatted_message = format_inter_session_message(message, sender_session_key)
        timeout_ms = timeout_seconds * 1000

        try do
          case SessionWorker.send_message(session_key, formatted_message, from_session: sender_session_key, timeout: timeout_ms) do
            {:ok, response} ->
              {:ok, format_response(response, session_key)}

            {:error, reason} ->
              Logger.warning(
                "Failed to send message to session #{session_key}: #{inspect(reason)}"
              )

              {:error, "Failed to send message: #{inspect(reason)}"}
          end
        catch
          :exit, {:timeout, _} ->
            {:error, "Timeout waiting for response from session #{session_key} after #{timeout_seconds}s"}

          :exit, reason ->
            Logger.error("Session communication failed: #{inspect(reason)}")
            {:error, "Session communication failed: #{inspect(reason)}"}
        end

      :not_found ->
        # 尝试启动会话
        case try_start_session(session_key) do
          {:ok, _pid} ->
            send_to_session(session_key, message, sender_session_key, timeout_seconds)

          {:error, reason} ->
            {:error, "Target session not found and could not be started: #{inspect(reason)}"}
        end
    end
  end

  defp try_start_session(session_key) do
    # 尝试从 session_key 解析 agent_id
    # session_key 格式通常是: "agent:<agent_name>:main" 或 "agent:<agent_name>:subagent:<uuid>"
    agent_id = extract_agent_id(session_key)

    SessionManager.start_session(
      session_key: session_key,
      agent_id: agent_id,
      channel: "internal"
    )
  end

  defp extract_agent_id(session_key) do
    case String.split(session_key, ":") do
      ["agent", agent_name | _rest] ->
        # 尝试通过名称查找 agent
        case ClawdEx.Repo.get_by(ClawdEx.Agents.Agent, name: agent_name) do
          nil -> nil
          agent -> agent.id
        end

      _ ->
        nil
    end
  end

  defp format_inter_session_message(message, sender_session_key) do
    """
    [Inter-session message from: #{sender_session_key}]

    #{message}
    """
  end

  defp format_response(response, session_key) do
    """
    ## Response from session: #{session_key}

    #{response}
    """
  end

  defp get_param(params, key) do
    params[to_string(key)] || params[key]
  end

  defp get_timeout(params) do
    raw_timeout = get_param(params, :timeoutSeconds)

    case raw_timeout do
      nil ->
        @default_timeout_seconds

      t when is_integer(t) and t > 0 and t <= @max_timeout_seconds ->
        t

      t when is_integer(t) and t > @max_timeout_seconds ->
        @max_timeout_seconds

      _ ->
        @default_timeout_seconds
    end
  end
end
