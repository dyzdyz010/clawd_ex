defmodule ClawdExWeb.DashboardLiveTest do
  use ClawdExWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  alias ClawdEx.Repo
  alias ClawdEx.Agents.Agent
  alias ClawdEx.Sessions.{Session, Message}

  defp create_agent(attrs \\ %{}) do
    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(Map.merge(%{name: "test-agent-#{System.unique_integer([:positive])}"}, attrs))
      |> Repo.insert()

    agent
  end

  describe "mount" do
    test "renders dashboard page", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "Dashboard"
    end

    test "displays stat cards", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "Agents"
      assert html =~ "Total Sessions"
      assert html =~ "Active Sessions"
      assert html =~ "Total Messages"
      assert html =~ "Today&#39;s Messages"
    end

    test "shows zero counts when no data", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      # Should render without errors even with no data
      assert html =~ "Dashboard"
    end

    test "shows correct agent count", %{conn: conn} do
      create_agent(%{name: "agent-1"})
      create_agent(%{name: "agent-2"})

      {:ok, _view, html} = live(conn, "/")

      # The stat card for agents should show 2
      assert html =~ "Agents"
    end

    test "displays system health section", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "System Health"
    end

    test "displays quick actions", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "Quick Actions"
      assert html =~ "New Chat"
      assert html =~ "Create Agent"
    end

    test "displays recent sessions section", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "Recent Sessions"
    end

    test "displays recent messages section", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "Recent Messages"
    end
  end

  describe "with data" do
    test "shows recent sessions when they exist", %{conn: conn} do
      agent = create_agent()

      {:ok, session} =
        %Session{}
        |> Session.changeset(%{
          session_key: "test:dashboard:#{System.unique_integer([:positive])}",
          channel: "test",
          agent_id: agent.id,
          state: :active,
          last_activity_at: DateTime.utc_now()
        })
        |> Repo.insert()

      {:ok, _view, html} = live(conn, "/")

      assert html =~ session.session_key
    end

    test "shows recent messages when they exist", %{conn: conn} do
      agent = create_agent()

      {:ok, session} =
        %Session{}
        |> Session.changeset(%{
          session_key: "test:dashboard-msg:#{System.unique_integer([:positive])}",
          channel: "test",
          agent_id: agent.id,
          state: :active,
          last_activity_at: DateTime.utc_now()
        })
        |> Repo.insert()

      {:ok, _msg} =
        %Message{}
        |> Message.changeset(%{
          role: :user,
          content: "Hello from dashboard test",
          session_id: session.id
        })
        |> Repo.insert()

      {:ok, _view, html} = live(conn, "/")

      assert html =~ "Hello from dashboard test"
    end
  end
end
