defmodule ClawdEx.Tools.SessionsList do
  @moduledoc """
  列出活跃会话工具

  参考 Clawdbot 的 sessions_list 实现:
  - 列出活跃会话
  - 支持按类型过滤 (kinds)
  - 支持按活跃时间过滤 (activeMinutes)
  - 支持分页 (limit)
  - 可选返回最近消息 (messageLimit)
  """
  @behaviour ClawdEx.Tools.Tool

  import Ecto.Query

  alias ClawdEx.Repo
  alias ClawdEx.Sessions.{Session, Message, SessionManager}

  @default_limit 20
  @default_active_minutes 60

  @impl true
  def name, do: "sessions_list"

  @impl true
  def description do
    "List active sessions with optional filtering by kind, activity time, and message preview."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        kinds: %{
          type: "array",
          items: %{type: "string"},
          description: "Filter by session kinds/channels (e.g., telegram, discord)"
        },
        limit: %{
          type: "integer",
          description: "Maximum number of sessions to return (default: #{@default_limit})"
        },
        activeMinutes: %{
          type: "integer",
          description:
            "Only show sessions active within N minutes (default: #{@default_active_minutes})"
        },
        messageLimit: %{
          type: "integer",
          description: "Include last N messages for each session (optional, default: 0)"
        }
      },
      required: []
    }
  end

  @impl true
  def execute(params, _context) do
    kinds = get_param(params, :kinds, ["kinds"])
    limit = get_param(params, :limit, ["limit"]) || @default_limit
    active_minutes = get_param(params, :activeMinutes, ["activeMinutes", "active_minutes"])
    message_limit = get_param(params, :messageLimit, ["messageLimit", "message_limit"]) || 0

    # 获取活跃会话进程的 session_keys
    active_keys = SessionManager.list_sessions()

    # 构建查询
    query =
      Session
      |> where([s], s.session_key in ^active_keys)
      |> maybe_filter_by_kinds(kinds)
      |> maybe_filter_by_activity(active_minutes)
      |> order_by([s], desc: s.last_activity_at)
      |> limit(^limit)

    # 执行查询
    sessions = Repo.all(query)

    # 格式化结果
    result =
      sessions
      |> Enum.map(&format_session(&1, message_limit))

    {:ok, %{sessions: result, count: length(result)}}
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp get_param(params, _atom_key, string_keys) do
    Enum.find_value(string_keys, fn key ->
      params[key] || params[String.to_atom(key)]
    end)
  end

  defp maybe_filter_by_kinds(query, nil), do: query
  defp maybe_filter_by_kinds(query, []), do: query

  defp maybe_filter_by_kinds(query, kinds) when is_list(kinds) do
    where(query, [s], s.channel in ^kinds)
  end

  defp maybe_filter_by_activity(query, nil), do: query

  defp maybe_filter_by_activity(query, minutes) when is_integer(minutes) and minutes > 0 do
    cutoff = DateTime.add(DateTime.utc_now(), -minutes * 60, :second)
    where(query, [s], s.last_activity_at >= ^cutoff)
  end

  defp maybe_filter_by_activity(query, _), do: query

  defp format_session(session, message_limit) do
    base = %{
      sessionKey: session.session_key,
      kind: session.channel,
      state: to_string(session.state),
      lastActivity: format_datetime(session.last_activity_at),
      messageCount: session.message_count,
      tokenCount: session.token_count
    }

    if message_limit > 0 do
      messages = load_recent_messages(session.id, message_limit)
      Map.put(base, :messages, messages)
    else
      base
    end
  end

  defp load_recent_messages(session_id, limit) do
    Message
    |> where([m], m.session_id == ^session_id)
    |> order_by([m], desc: m.inserted_at)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.reverse()
    |> Enum.map(fn m ->
      %{
        role: to_string(m.role),
        content: truncate_content(m.content, 200),
        timestamp: format_datetime(m.inserted_at)
      }
    end)
  end

  defp truncate_content(nil, _max_length), do: nil
  defp truncate_content(content, max_length) when byte_size(content) <= max_length, do: content

  defp truncate_content(content, max_length) do
    String.slice(content, 0, max_length) <> "..."
  end

  defp format_datetime(nil), do: nil

  defp format_datetime(dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
  end
end
