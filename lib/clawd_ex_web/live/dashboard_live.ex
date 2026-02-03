defmodule ClawdExWeb.DashboardLive do
  @moduledoc """
  Dashboard - 系统概览页面
  """
  use ClawdExWeb, :live_view

  import ClawdExWeb.DashboardComponents
  import ClawdExWeb.SessionComponents

  import Ecto.Query
  alias ClawdEx.Repo
  alias ClawdEx.Agents.Agent
  alias ClawdEx.Sessions.{Session, Message}
  alias ClawdEx.Health

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # 每 30 秒刷新一次统计
      :timer.send_interval(30_000, self(), :refresh_stats)
    end

    socket =
      socket
      |> assign(:page_title, "Dashboard")
      |> load_stats()
      |> load_recent_activity()
      |> load_health()

    {:ok, socket}
  end

  @impl true
  def handle_info(:refresh_stats, socket) do
    socket =
      socket
      |> load_stats()
      |> load_recent_activity()
      |> load_health()

    {:noreply, socket}
  end

  defp load_health(socket) do
    health = Health.full_check()
    assign(socket, health: health)
  end

  defp load_stats(socket) do
    agents_count = Repo.aggregate(Agent, :count, :id)
    sessions_count = Repo.aggregate(Session, :count, :id)
    active_sessions = Repo.aggregate(from(s in Session, where: s.state == :active), :count, :id)
    messages_count = Repo.aggregate(Message, :count, :id)

    # 今日消息数
    today_start = Date.utc_today() |> DateTime.new!(~T[00:00:00], "Etc/UTC")

    today_messages =
      Repo.aggregate(
        from(m in Message, where: m.inserted_at >= ^today_start),
        :count,
        :id
      )

    assign(socket,
      agents_count: agents_count,
      sessions_count: sessions_count,
      active_sessions: active_sessions,
      messages_count: messages_count,
      today_messages: today_messages
    )
  end

  defp load_recent_activity(socket) do
    # 最近 10 个会话
    recent_sessions =
      from(s in Session,
        order_by: [desc: s.last_activity_at],
        limit: 10,
        preload: [:agent]
      )
      |> Repo.all()

    # 最近 20 条消息
    recent_messages =
      from(m in Message,
        order_by: [desc: m.inserted_at],
        limit: 20,
        preload: [:session]
      )
      |> Repo.all()

    assign(socket,
      recent_sessions: recent_sessions,
      recent_messages: recent_messages
    )
  end

  defp format_time(nil), do: "-"

  defp format_time(datetime) do
    now = DateTime.utc_now()
    diff = DateTime.diff(now, datetime, :second)

    cond do
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86400 -> "#{div(diff, 3600)}h ago"
      true -> Calendar.strftime(datetime, "%Y-%m-%d %H:%M")
    end
  end

  defp truncate_content(nil, _max_length), do: ""

  defp truncate_content(content, max_length) do
    if String.length(content) > max_length do
      String.slice(content, 0, max_length) <> "..."
    else
      content
    end
  end

  defp health_check_icon(:ok), do: "✓"
  defp health_check_icon(:warning), do: "⚠"
  defp health_check_icon(:error), do: "✗"
  defp health_check_icon(_), do: "?"

  defp health_check_color(:ok), do: "text-green-400"
  defp health_check_color(:warning), do: "text-yellow-400"
  defp health_check_color(:error), do: "text-red-400"
  defp health_check_color(_), do: "text-gray-400"

  defp health_check_bg(:ok), do: "bg-green-500/10"
  defp health_check_bg(:warning), do: "bg-yellow-500/10"
  defp health_check_bg(:error), do: "bg-red-500/10"
  defp health_check_bg(_), do: "bg-gray-500/10"
end
