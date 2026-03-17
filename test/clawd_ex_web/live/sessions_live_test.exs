defmodule ClawdExWeb.SessionsLiveTest do
  use ClawdExWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  alias ClawdEx.Repo
  alias ClawdEx.Agents.Agent
  alias ClawdEx.Sessions.Session

  defp create_agent do
    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{name: "test-agent-#{System.unique_integer([:positive])}", active: true})
      |> Repo.insert()

    agent
  end

  defp create_session(attrs \\ %{}) do
    agent = create_agent()

    defaults = %{
      session_key: "test:session:#{System.unique_integer([:positive])}",
      channel: "test",
      agent_id: agent.id,
      state: :active
    }

    {:ok, session} =
      %Session{}
      |> Session.changeset(Map.merge(defaults, attrs))
      |> Repo.insert()

    session
  end

  describe "mount" do
    test "renders sessions page with title", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/sessions")

      assert html =~ "Sessions"
    end

    test "shows empty state when no sessions", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/sessions")

      assert html =~ "No sessions found"
    end

    test "contains key UI elements", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/sessions")

      # Title
      assert html =~ "Sessions"
      # New Chat link
      assert html =~ "New Chat"
      # Filter buttons
      assert html =~ "All"
      assert html =~ "Active"
      assert html =~ "Idle"
      assert html =~ "Archived"
      # Search box
      assert html =~ "Search sessions"
      # Table headers
      assert html =~ "Session Key"
      assert html =~ "Agent"
      assert html =~ "Channel"
      assert html =~ "State"
      assert html =~ "Messages"
      assert html =~ "Last Activity"
    end

    test "renders sessions when they exist", %{conn: conn} do
      session = create_session(%{session_key: "my:test:session"})
      {:ok, _view, html} = live(conn, "/sessions")

      assert html =~ "my:test:session"
      refute html =~ "No sessions found"

      # Should show the agent name
      agent = Repo.get!(Agent, session.agent_id)
      assert html =~ agent.name
    end
  end

  describe "events" do
    test "filter event does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/sessions")

      html = render_click(view, "filter", %{"state" => "active"})
      assert html =~ "Sessions"

      html = render_click(view, "filter", %{"state" => "idle"})
      assert html =~ "Sessions"

      html = render_click(view, "filter", %{"state" => "all"})
      assert html =~ "Sessions"
    end

    test "filter shows only matching sessions", %{conn: conn} do
      create_session(%{session_key: "active:sess", state: :active})
      create_session(%{session_key: "idle:sess", state: :idle})

      {:ok, view, _html} = live(conn, "/sessions")

      html = render_click(view, "filter", %{"state" => "active"})
      assert html =~ "active:sess"
      refute html =~ "idle:sess"

      html = render_click(view, "filter", %{"state" => "idle"})
      refute html =~ "active:sess"
      assert html =~ "idle:sess"
    end

    test "search event does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/sessions")

      html = render_keyup(view, "search", %{"search" => "test"})
      assert html =~ "Sessions"
    end

    test "search filters sessions by key", %{conn: conn} do
      create_session(%{session_key: "alpha:session:1"})
      create_session(%{session_key: "beta:session:2"})

      {:ok, view, _html} = live(conn, "/sessions")

      html = render_keyup(view, "search", %{"search" => "alpha"})
      assert html =~ "alpha:session:1"
      refute html =~ "beta:session:2"
    end

    test "delete event removes a session", %{conn: conn} do
      session = create_session(%{session_key: "deletable:session"})
      {:ok, view, html} = live(conn, "/sessions")
      assert html =~ "deletable:session"

      html = render_click(view, "delete", %{"id" => to_string(session.id)})
      refute html =~ "deletable:session"
    end

    test "archive event archives a session", %{conn: conn} do
      session = create_session(%{session_key: "archivable:session", state: :active})
      {:ok, view, _html} = live(conn, "/sessions")

      render_click(view, "archive", %{"id" => to_string(session.id)})

      updated = Repo.get!(Session, session.id)
      assert updated.state == :archived
    end
  end
end
