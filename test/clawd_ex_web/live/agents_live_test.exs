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

  describe "mount" do
    test "renders agents page", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/agents")

      assert html =~ "Agents"
    end

    test "shows empty state when no agents", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/agents")

      # Should render without errors
      assert html =~ "Agents"
    end

    test "displays agents when they exist", %{conn: conn} do
      create_agent(%{name: "my-test-agent"})

      {:ok, _view, html} = live(conn, "/agents")

      assert html =~ "my-test-agent"
    end

    test "displays multiple agents", %{conn: conn} do
      create_agent(%{name: "agent-alpha"})
      create_agent(%{name: "agent-beta"})

      {:ok, _view, html} = live(conn, "/agents")

      assert html =~ "agent-alpha"
      assert html =~ "agent-beta"
    end

    test "has create new agent link", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/agents")

      assert html =~ ~p"/agents/new"
    end
  end

  describe "events" do
    test "toggle_active deactivates an active agent", %{conn: conn} do
      agent = create_agent(%{name: "toggle-agent", active: true})

      {:ok, view, _html} = live(conn, "/agents")

      view
      |> render_click("toggle_active", %{"id" => to_string(agent.id)})

      html = render(view)
      assert html =~ "deactivated"
    end

    test "toggle_active activates an inactive agent", %{conn: conn} do
      agent = create_agent(%{name: "inactive-agent", active: false})

      {:ok, view, _html} = live(conn, "/agents")

      view
      |> render_click("toggle_active", %{"id" => to_string(agent.id)})

      html = render(view)
      assert html =~ "activated"
    end

    test "delete removes an agent", %{conn: conn} do
      agent = create_agent(%{name: "delete-me-agent"})

      {:ok, view, _html} = live(conn, "/agents")

      view
      |> render_click("delete", %{"id" => to_string(agent.id)})

      html = render(view)
      assert html =~ "Agent deleted"
      refute html =~ "delete-me-agent"
    end
  end
end
