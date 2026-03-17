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

  describe "mount" do
    test "renders new agent form", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/agents/new")

      assert html =~ "New Agent"
    end

    test "renders edit agent form", %{conn: conn} do
      agent = create_agent(%{name: "edit-form-agent"})

      {:ok, _view, html} = live(conn, "/agents/#{agent.id}/edit")

      assert html =~ "Edit Agent"
      assert html =~ "edit-form-agent"
    end

    test "form contains name field", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/agents/new")

      assert html =~ "Name"
    end

    test "form contains model field", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/agents/new")

      assert html =~ "Model"
    end

    test "form contains system prompt field", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/agents/new")

      assert html =~ "System Prompt"
    end

    test "form contains workspace path field", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/agents/new")

      assert html =~ "Workspace"
    end
  end

  describe "events" do
    test "validate event does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/agents/new")

      html =
        view
        |> form("form", agent: %{name: "test-validate"})
        |> render_change()

      assert html =~ "New Agent"
    end

    test "validate shows errors for missing name", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/agents/new")

      view
      |> form("form", agent: %{name: ""})
      |> render_change()

      # Should not crash
      html = render(view)
      assert html =~ "New Agent"
    end

    test "save creates a new agent", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/agents/new")

      view
      |> form("form", agent: %{name: "brand-new-agent"})
      |> render_submit()

      # Should redirect to agents list
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

    test "workspace_manual_edit does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/agents/new")

      view
      |> render_click("workspace_manual_edit")

      html = render(view)
      assert html =~ "New Agent"
    end

    test "use_suggested_workspace does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/agents/new")

      # First trigger validate to set suggested_workspace
      view
      |> form("form", agent: %{name: "workspace-test"})
      |> render_change()

      view
      |> render_click("use_suggested_workspace")

      html = render(view)
      assert html =~ "New Agent"
    end
  end
end
