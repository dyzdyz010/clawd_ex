defmodule ClawdExWeb.SessionsLive do
  @moduledoc """
  Sessions 列表页面
  """
  use ClawdExWeb, :live_view

  import Ecto.Query
  alias ClawdEx.Repo
  alias ClawdEx.Sessions.Session

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Sessions")
      |> assign(:filter_state, "all")
      |> assign(:search, "")
      |> load_sessions()

    {:ok, socket}
  end

  @impl true
  def handle_event("filter", %{"state" => state}, socket) do
    socket =
      socket
      |> assign(:filter_state, state)
      |> load_sessions()

    {:noreply, socket}
  end

  @impl true
  def handle_event("search", %{"search" => search}, socket) do
    socket =
      socket
      |> assign(:search, search)
      |> load_sessions()

    {:noreply, socket}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    session = Repo.get!(Session, id)
    {:ok, _} = Repo.delete(session)

    socket =
      socket
      |> put_flash(:info, "Session deleted")
      |> load_sessions()

    {:noreply, socket}
  end

  @impl true
  def handle_event("archive", %{"id" => id}, socket) do
    session = Repo.get!(Session, id)
    {:ok, _} = session |> Session.changeset(%{state: :archived}) |> Repo.update()

    socket =
      socket
      |> put_flash(:info, "Session archived")
      |> load_sessions()

    {:noreply, socket}
  end

  defp load_sessions(socket) do
    alias ClawdEx.Sessions.Message

    query =
      from(s in Session,
        left_join: m in Message, on: m.session_id == s.id,
        left_join: a in assoc(s, :agent),
        group_by: [s.id, a.id],
        select: %{session: s, agent: a, message_count: count(m.id)},
        order_by: [desc: s.last_activity_at, desc: s.updated_at]
      )

    query =
      case socket.assigns.filter_state do
        "all" -> query
        state -> from([s, m, a] in query, where: s.state == ^String.to_existing_atom(state))
      end

    query =
      case socket.assigns.search do
        "" -> query
        search -> from([s, m, a] in query, where: ilike(s.session_key, ^"%#{search}%"))
      end

    results = Repo.all(query)
    # 将 agent 嵌入 session 结构，添加实际消息数
    sessions = Enum.map(results, fn %{session: s, agent: a, message_count: mc} ->
      %{s | agent: a, message_count: mc}
    end)

    assign(socket, :sessions, sessions)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-7xl mx-auto px-4 py-8">
        <div class="flex justify-between items-center mb-8">
          <h1 class="text-3xl font-bold">Sessions</h1>
          <.link navigate={~p"/chat"} class="btn-primary">
            + New Chat
          </.link>
        </div>

        <!-- Filters -->
        <div class="bg-gray-800 rounded-lg p-4 mb-6">
          <div class="flex flex-wrap gap-4 items-center">
            <div class="flex-1 min-w-64">
              <input
                type="text"
                placeholder="Search sessions..."
                value={@search}
                phx-keyup="search"
                phx-key="Enter"
                phx-debounce="300"
                name="search"
                class="w-full bg-gray-700 border-gray-600 rounded-lg px-4 py-2 text-white placeholder-gray-400 focus:ring-blue-500 focus:border-blue-500"
              />
            </div>
            <div class="flex gap-2">
              <.filter_button state="all" current={@filter_state} label="All" />
              <.filter_button state="active" current={@filter_state} label="Active" />
              <.filter_button state="idle" current={@filter_state} label="Idle" />
              <.filter_button state="archived" current={@filter_state} label="Archived" />
            </div>
          </div>
        </div>

        <!-- Sessions Table -->
        <div class="bg-gray-800 rounded-lg overflow-hidden">
          <table class="w-full">
            <thead class="bg-gray-700">
              <tr>
                <th class="px-4 py-3 text-left text-sm font-medium">Session Key</th>
                <th class="px-4 py-3 text-left text-sm font-medium">Agent</th>
                <th class="px-4 py-3 text-left text-sm font-medium">Channel</th>
                <th class="px-4 py-3 text-left text-sm font-medium">State</th>
                <th class="px-4 py-3 text-left text-sm font-medium">Messages</th>
                <th class="px-4 py-3 text-left text-sm font-medium">Last Activity</th>
                <th class="px-4 py-3 text-left text-sm font-medium">Actions</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-700">
              <%= for session <- @sessions do %>
                <tr class="hover:bg-gray-750">
                  <td class="px-4 py-3">
                    <.link navigate={~p"/sessions/#{session.id}"} class="text-blue-400 hover:text-blue-300">
                      <span class="font-mono text-sm truncate max-w-xs block">
                        <%= truncate(session.session_key, 30) %>
                      </span>
                    </.link>
                  </td>
                  <td class="px-4 py-3">
                    <%= if session.agent, do: session.agent.name, else: "-" %>
                  </td>
                  <td class="px-4 py-3">
                    <span class="text-sm text-gray-400"><%= session.channel %></span>
                  </td>
                  <td class="px-4 py-3">
                    <.session_state_badge state={session.state} />
                  </td>
                  <td class="px-4 py-3">
                    <span class="text-sm"><%= session.message_count %></span>
                  </td>
                  <td class="px-4 py-3">
                    <span class="text-sm text-gray-400">
                      <%= format_time(session.last_activity_at || session.updated_at) %>
                    </span>
                  </td>
                  <td class="px-4 py-3">
                    <div class="flex gap-2">
                      <.link navigate={~p"/sessions/#{session.id}"} class="text-blue-400 hover:text-blue-300 text-sm">
                        View
                      </.link>
                      <%= if session.state != :archived do %>
                        <button
                          phx-click="archive"
                          phx-value-id={session.id}
                          class="text-yellow-400 hover:text-yellow-300 text-sm"
                        >
                          Archive
                        </button>
                      <% end %>
                      <button
                        phx-click="delete"
                        phx-value-id={session.id}
                        data-confirm="Are you sure you want to delete this session?"
                        class="text-red-400 hover:text-red-300 text-sm"
                      >
                        Delete
                      </button>
                    </div>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
          <%= if Enum.empty?(@sessions) do %>
            <div class="text-center py-12 text-gray-500">
              No sessions found
            </div>
          <% end %>
        </div>
      </div>
    """
  end

  defp filter_button(assigns) do
    active = assigns.state == assigns.current
    assigns = assign(assigns, :active, active)

    ~H"""
    <button
      phx-click="filter"
      phx-value-state={@state}
      class={"px-4 py-2 rounded-lg text-sm font-medium transition-colors " <>
        if(@active, do: "bg-blue-600 text-white", else: "bg-gray-700 text-gray-300 hover:bg-gray-600")}
    >
      <%= @label %>
    </button>
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

  defp truncate(nil, _), do: ""
  defp truncate(string, max) when byte_size(string) > max do
    String.slice(string, 0, max) <> "..."
  end
  defp truncate(string, _), do: string
end
