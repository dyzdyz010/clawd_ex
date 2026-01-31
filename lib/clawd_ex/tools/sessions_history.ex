defmodule ClawdEx.Tools.SessionsHistory do
  @moduledoc """
  会话历史工具 - 获取会话消息历史
  """
  @behaviour ClawdEx.Tools.Tool

  import Ecto.Query

  alias ClawdEx.Repo
  alias ClawdEx.Sessions.{Session, Message}

  @default_limit 50

  @impl true
  def name, do: "sessions_history"

  @impl true
  def description do
    "Get message history for a session. Returns messages in chronological order."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        sessionKey: %{
          type: "string",
          description: "Session key to get history for (required)"
        },
        limit: %{
          type: "integer",
          description: "Maximum number of messages to return (default: 50)"
        },
        includeTools: %{
          type: "boolean",
          description: "Include tool calls and tool results (default: true)"
        }
      },
      required: ["sessionKey"]
    }
  end

  @impl true
  def execute(params, _context) do
    session_key = params["sessionKey"] || params[:sessionKey]
    limit = params["limit"] || params[:limit] || @default_limit
    include_tools = get_include_tools(params)

    if is_nil(session_key) || session_key == "" do
      {:error, "sessionKey is required"}
    else
      fetch_history(session_key, limit, include_tools)
    end
  end

  defp get_include_tools(params) do
    # Can't use || here because false is falsy - use Map.get with fallback
    raw = 
      case Map.get(params, "includeTools") do
        nil -> Map.get(params, :includeTools)
        val -> val
      end
      
    case raw do
      nil -> true
      val when is_boolean(val) -> val
      "true" -> true
      "false" -> false
      _ -> true
    end
  end

  defp fetch_history(session_key, limit, include_tools) do
    case Repo.get_by(Session, session_key: session_key) do
      nil ->
        {:error, "Session not found: #{session_key}"}

      session ->
        messages = fetch_messages(session.id, limit, include_tools)
        {:ok, format_response(session, messages)}
    end
  end

  defp fetch_messages(session_id, limit, include_tools) do
    query =
      from m in Message,
        where: m.session_id == ^session_id,
        order_by: [asc: m.inserted_at, asc: m.id],
        limit: ^limit

    if include_tools do
      Repo.all(query)
    else
      # Filter out tool messages - Ecto.Enum uses atoms
      query
      |> where([m], m.role != ^:tool)
      |> Repo.all()
    end
  end

  defp format_response(session, messages) do
    %{
      sessionKey: session.session_key,
      channel: session.channel,
      messageCount: length(messages),
      messages: Enum.map(messages, &format_message/1)
    }
  end

  defp format_message(message) do
    base = %{
      id: message.id,
      role: message.role,
      content: message.content,
      timestamp: format_datetime(message.inserted_at)
    }

    base
    |> maybe_add_tool_calls(message)
    |> maybe_add_tool_call_id(message)
    |> maybe_add_model(message)
    |> maybe_add_tokens(message)
  end

  defp maybe_add_tool_calls(map, %{tool_calls: calls}) when is_list(calls) and calls != [] do
    Map.put(map, :toolCalls, calls)
  end

  defp maybe_add_tool_calls(map, _), do: map

  defp maybe_add_tool_call_id(map, %{tool_call_id: id}) when is_binary(id) and id != "" do
    Map.put(map, :toolCallId, id)
  end

  defp maybe_add_tool_call_id(map, _), do: map

  defp maybe_add_model(map, %{model: model}) when is_binary(model) and model != "" do
    Map.put(map, :model, model)
  end

  defp maybe_add_model(map, _), do: map

  defp maybe_add_tokens(map, %{tokens_in: tin, tokens_out: tout})
       when is_integer(tin) or is_integer(tout) do
    map
    |> maybe_put(:tokensIn, tin)
    |> maybe_put(:tokensOut, tout)
  end

  defp maybe_add_tokens(map, _), do: map

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, val), do: Map.put(map, key, val)

  defp format_datetime(nil), do: nil

  defp format_datetime(dt) do
    Calendar.strftime(dt, "%Y-%m-%dT%H:%M:%SZ")
  end
end
