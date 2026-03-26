defmodule ClawdExWeb.AgentsLiveTest do
  use ClawdExWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  alias ClawdEx.Repo
  alias ClawdEx.Agents.Agent

  defp create_agent(attrs \\ %{}) do
    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(Map.merge(%{name: "test-agent-#{System.unique_integer([:positive])}"}, attrs))
      |> Repo.insert()

    agent
  end

  test "renders agents page with key elements", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/agents")

    assert html =~ "Agents"
    assert html =~ ~p"/agents/new"
  end

  test "displays agents when they exist", %{conn: conn} do
    create_agent(%{name: "agent-alpha"})
    create_agent(%{name: "agent-beta"})

    {:ok, _view, html} = live(conn, "/agents")

    assert html =~ "agent-alpha"
    assert html =~ "agent-beta"
  end

  test "toggle_active toggles agent state", %{conn: conn} do
    agent = create_agent(%{name: "toggle-agent", active: true})

    {:ok, view, _html} = live(conn, "/agents")

    html = view |> render_click("toggle_active", %{"id" => to_string(agent.id)})
    assert html =~ "deactivated"
  end

  test "delete removes an agent", %{conn: conn} do
    agent = create_agent(%{name: "delete-me-agent"})

    {:ok, view, _html} = live(conn, "/agents")

    html = view |> render_click("delete", %{"id" => to_string(agent.id)})
    assert html =~ "Agent deleted"
    refute html =~ "delete-me-agent"
  end
end
