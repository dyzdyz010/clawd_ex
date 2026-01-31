defmodule ClawdEx.Tools.SessionStatus do
  @moduledoc """
  会话状态工具
  """
  @behaviour ClawdEx.Tools.Tool

  alias ClawdEx.Repo
  alias ClawdEx.Sessions.Session

  @impl true
  def name, do: "session_status"

  @impl true
  def description do
    "Show current session status including usage, time, and cost when available."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        session_key: %{
          type: "string",
          description: "Session key (optional, defaults to current session)"
        }
      },
      required: []
    }
  end

  @impl true
  def execute(params, context) do
    session_id = params["session_id"] || params[:session_id] || context[:session_id]

    if is_nil(session_id) do
      {:error, "No session context available"}
    else
      case Repo.get(Session, session_id) do
        nil ->
          {:error, "Session not found"}

        session ->
          status = format_session_status(session)
          {:ok, status}
      end
    end
  end

  defp format_session_status(session) do
    """
    ## Session Status

    - **Session Key:** #{session.session_key}
    - **Channel:** #{session.channel}
    - **State:** #{session.state}
    - **Model:** #{session.model_override || "default"}
    - **Messages:** #{session.message_count}
    - **Tokens:** #{session.token_count}
    - **Last Activity:** #{format_datetime(session.last_activity_at)}
    - **Created:** #{format_datetime(session.inserted_at)}
    """
  end

  defp format_datetime(nil), do: "N/A"

  defp format_datetime(dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
  end
end
