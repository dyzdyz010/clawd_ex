defmodule ClawdExWeb.AgentsLive do
  @moduledoc """
  Agents 列表和管理页面
  """
  use ClawdExWeb, :live_view

  import Ecto.Query
  alias ClawdEx.Repo
  alias ClawdEx.Agents.Agent

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Agents")
      |> load_agents()

    {:ok, socket}
  end

  @impl true
  def handle_event("toggle_active", %{"id" => id}, socket) do
    agent = Repo.get!(Agent, id)
    {:ok, _} = agent |> Agent.changeset(%{active: !agent.active}) |> Repo.update()

    socket =
      socket
      |> put_flash(:info, "Agent #{if agent.active, do: "deactivated", else: "activated"}")
      |> load_agents()

    {:noreply, socket}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    agent = Repo.get!(Agent, id)

    case Repo.delete(agent) do
      {:ok, _} ->
        socket =
          socket
          |> put_flash(:info, "Agent deleted")
          |> load_agents()

        {:noreply, socket}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Cannot delete agent with active sessions")}
    end
  end

  defp load_agents(socket) do
    agents =
      from(a in Agent,
        left_join: s in assoc(a, :sessions),
        group_by: a.id,
        select: %{agent: a, session_count: count(s.id)},
        order_by: [desc: a.updated_at]
      )
      |> Repo.all()

    assign(socket, :agents, agents)
  end

  defp truncate(nil, _), do: "-"

  defp truncate(string, max) when byte_size(string) > max do
    String.slice(string, 0, max) <> "..."
  end

  defp truncate(string, _), do: string
end
