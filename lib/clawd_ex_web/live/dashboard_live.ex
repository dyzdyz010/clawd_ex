defmodule ClawdExWeb.DashboardLive do
  @moduledoc """
  Dashboard - 系统概览页面
  """
  use ClawdExWeb, :live_view

  import Ecto.Query
  alias ClawdEx.Repo
  alias ClawdEx.Agents.Agent
  alias ClawdEx.Sessions.{Session, Message}

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

    {:ok, socket}
  end

  @impl true
  def handle_info(:refresh_stats, socket) do
    socket =
      socket
      |> load_stats()
      |> load_recent_activity()

    {:noreply, socket}
  end

  defp load_stats(socket) do
    agents_count = Repo.aggregate(Agent, :count, :id)
    sessions_count = Repo.aggregate(Session, :count, :id)
    active_sessions = Repo.aggregate(from(s in Session, where: s.state == :active), :count, :id)
    messages_count = Repo.aggregate(Message, :count, :id)

    # 今日消息数
    today_start = Date.utc_today() |> DateTime.new!(~T[00:00:00], "Etc/UTC")
    today_messages = Repo.aggregate(
      from(m in Message, where: m.inserted_at >= ^today_start),
      :count, :id
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

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-7xl mx-auto px-4 py-8">
        <h1 class="text-3xl font-bold mb-8">Dashboard</h1>

        <!-- Stats Cards -->
        <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-5 gap-4 mb-8">
          <.stat_card title="Agents" value={@agents_count} icon="🤖" color="blue" />
          <.stat_card title="Total Sessions" value={@sessions_count} icon="💬" color="purple" />
          <.stat_card title="Active Sessions" value={@active_sessions} icon="🟢" color="green" />
          <.stat_card title="Total Messages" value={@messages_count} icon="📝" color="yellow" />
          <.stat_card title="Today's Messages" value={@today_messages} icon="📅" color="pink" />
        </div>

        <div class="grid grid-cols-1 lg:grid-cols-2 gap-8">
          <!-- Recent Sessions -->
          <div class="bg-gray-800 rounded-lg p-6">
            <div class="flex justify-between items-center mb-4">
              <h2 class="text-xl font-semibold">Recent Sessions</h2>
              <.link navigate={~p"/sessions"} class="text-blue-400 hover:text-blue-300 text-sm">
                View All →
              </.link>
            </div>
            <div class="space-y-3">
              <%= for session <- @recent_sessions do %>
                <.link navigate={~p"/sessions/#{session.id}"} class="block">
                  <div class="bg-gray-700 rounded-lg p-3 hover:bg-gray-600 transition-colors">
                    <div class="flex justify-between items-start">
                      <div>
                        <div class="font-medium truncate max-w-xs">
                          <%= session.session_key %>
                        </div>
                        <div class="text-sm text-gray-400">
                          <%= if session.agent, do: session.agent.name, else: "No Agent" %>
                          · <%= session.channel %>
                        </div>
                      </div>
                      <.session_state_badge state={session.state} />
                    </div>
                    <div class="text-xs text-gray-500 mt-1">
                      <%= format_time(session.last_activity_at) %>
                    </div>
                  </div>
                </.link>
              <% end %>
              <%= if Enum.empty?(@recent_sessions) do %>
                <div class="text-gray-500 text-center py-4">No sessions yet</div>
              <% end %>
            </div>
          </div>

          <!-- Recent Messages -->
          <div class="bg-gray-800 rounded-lg p-6">
            <h2 class="text-xl font-semibold mb-4">Recent Messages</h2>
            <div class="space-y-2 max-h-96 overflow-y-auto">
              <%= for message <- @recent_messages do %>
                <div class="bg-gray-700 rounded-lg p-3">
                  <div class="flex items-center gap-2 mb-1">
                    <.role_badge role={message.role} />
                    <span class="text-xs text-gray-500">
                      <%= format_time(message.inserted_at) %>
                    </span>
                  </div>
                  <div class="text-sm text-gray-300 truncate">
                    <%= truncate_content(message.content, 100) %>
                  </div>
                </div>
              <% end %>
              <%= if Enum.empty?(@recent_messages) do %>
                <div class="text-gray-500 text-center py-4">No messages yet</div>
              <% end %>
            </div>
          </div>
        </div>

        <!-- Quick Actions -->
        <div class="mt-8 bg-gray-800 rounded-lg p-6">
          <h2 class="text-xl font-semibold mb-4">Quick Actions</h2>
          <div class="flex flex-wrap gap-4">
            <.link navigate={~p"/chat"} class="btn-primary">
              💬 New Chat
            </.link>
            <.link navigate={~p"/agents/new"} class="btn-secondary">
              🤖 Create Agent
            </.link>
            <.link navigate={~p"/sessions"} class="btn-secondary">
              📋 Manage Sessions
            </.link>
            <.link navigate={~p"/agents"} class="btn-secondary">
              ⚙️ Manage Agents
            </.link>
          </div>
        </div>
      </div>
    """
  end

  # Components

  defp stat_card(assigns) do
    color_classes = %{
      "blue" => "from-blue-600 to-blue-800",
      "purple" => "from-purple-600 to-purple-800",
      "green" => "from-green-600 to-green-800",
      "yellow" => "from-yellow-600 to-yellow-800",
      "pink" => "from-pink-600 to-pink-800"
    }

    assigns = assign(assigns, :gradient, color_classes[assigns.color] || color_classes["blue"])

    ~H"""
    <div class={"bg-gradient-to-br #{@gradient} rounded-lg p-4"}>
      <div class="flex items-center justify-between">
        <div>
          <div class="text-sm text-gray-200 opacity-80"><%= @title %></div>
          <div class="text-2xl font-bold"><%= @value %></div>
        </div>
        <div class="text-3xl"><%= @icon %></div>
      </div>
    </div>
    """
  end

  defp session_state_badge(assigns) do
    {bg, text} = case assigns.state do
      :active -> {"bg-green-500", "Active"}
      :idle -> {"bg-gray-500", "Idle"}
      :compacting -> {"bg-yellow-500", "Compacting"}
      :archived -> {"bg-red-500", "Archived"}
      _ -> {"bg-gray-500", "Unknown"}
    end

    assigns = assign(assigns, bg: bg, text: text)

    ~H"""
    <span class={"text-xs px-2 py-1 rounded-full #{@bg}"}><%= @text %></span>
    """
  end

  defp role_badge(assigns) do
    {bg, text} = case assigns.role do
      :user -> {"bg-blue-600", "User"}
      :assistant -> {"bg-green-600", "AI"}
      :system -> {"bg-gray-600", "Sys"}
      :tool -> {"bg-purple-600", "Tool"}
      _ -> {"bg-gray-600", "?"}
    end

    assigns = assign(assigns, bg: bg, text: text)

    ~H"""
    <span class={"text-xs px-2 py-0.5 rounded #{@bg}"}><%= @text %></span>
    """
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

  defp truncate_content(nil), do: ""
  defp truncate_content(content, max_length \\ 100) do
    if String.length(content) > max_length do
      String.slice(content, 0, max_length) <> "..."
    else
      content
    end
  end
end
