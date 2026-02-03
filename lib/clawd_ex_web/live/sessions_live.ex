defmodule ClawdExWeb.SessionsLive do
  @moduledoc """
  Sessions 列表页面
  """
  use ClawdExWeb, :live_view

  import ClawdExWeb.SessionComponents
  import ClawdExWeb.SessionsComponents

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
        left_join: m in Message,
        on: m.session_id == s.id,
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
    sessions =
      Enum.map(results, fn %{session: s, agent: a, message_count: mc} ->
        %{s | agent: a, message_count: mc}
      end)

    assign(socket, :sessions, sessions)
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
