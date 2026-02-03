defmodule ClawdExWeb.SessionDetailLive do
  @moduledoc """
  Session 详情页面 - 查看消息历史和会话信息
  """
  use ClawdExWeb, :live_view

  import ClawdExWeb.SessionComponents

  import Ecto.Query
  alias ClawdEx.Repo
  alias ClawdEx.Sessions.{Session, Message}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    session = Repo.get!(Session, id) |> Repo.preload(:agent)

    socket =
      socket
      |> assign(:page_title, "Session: #{truncate(session.session_key, 20)}")
      |> assign(:session, session)
      |> load_messages()

    {:ok, socket}
  end

  @impl true
  def handle_event("load_more", _, socket) do
    {:noreply, load_messages(socket, socket.assigns.offset + 50)}
  end

  @impl true
  def handle_event("delete_message", %{"id" => id}, socket) do
    message = Repo.get!(Message, id)
    {:ok, _} = Repo.delete(message)

    socket =
      socket
      |> put_flash(:info, "Message deleted")
      |> load_messages()

    {:noreply, socket}
  end

  defp load_messages(socket, offset \\ 0) do
    session = socket.assigns.session

    messages =
      from(m in Message,
        where: m.session_id == ^session.id,
        order_by: [asc: m.inserted_at],
        limit: 50,
        offset: ^offset
      )
      |> Repo.all()

    total_count =
      from(m in Message, where: m.session_id == ^session.id)
      |> Repo.aggregate(:count, :id)

    socket
    |> assign(:messages, messages)
    |> assign(:offset, offset)
    |> assign(:total_count, total_count)
    |> assign(:has_more, offset + length(messages) < total_count)
  end

  defp truncate(nil, _), do: ""

  defp truncate(string, max) when byte_size(string) > max do
    String.slice(string, 0, max) <> "..."
  end

  defp truncate(string, _), do: string
end
