defmodule ClawdExWeb.AgentFormLiveTest do
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

  test "renders new agent form with key fields", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/agents/new")

    assert html =~ "New Agent"
    assert html =~ "Name"
    assert html =~ "Model"
    assert html =~ "System Prompt"
    assert html =~ "Workspace"
  end

  test "renders edit agent form", %{conn: conn} do
    agent = create_agent(%{name: "edit-form-agent"})

    {:ok, _view, html} = live(conn, "/agents/#{agent.id}/edit")

    assert html =~ "Edit Agent"
    assert html =~ "edit-form-agent"
  end

  test "save creates a new agent", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/agents/new")

    view
    |> form("form", agent: %{name: "brand-new-agent"})
    |> render_submit()

    assert_redirect(view, "/agents")
  end

  test "save updates an existing agent", %{conn: conn} do
    agent = create_agent(%{name: "update-me-agent"})

    {:ok, view, _html} = live(conn, "/agents/#{agent.id}/edit")

    view
    |> form("form", agent: %{name: "updated-agent-name"})
    |> render_submit()

    assert_redirect(view, "/agents")
  end

  test "workspace events do not crash", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/agents/new")

    view |> render_click("workspace_manual_edit")

    view
    |> form("form", agent: %{name: "workspace-test"})
    |> render_change()

    view |> render_click("use_suggested_workspace")

    html = render(view)
    assert html =~ "New Agent"
  end
end
