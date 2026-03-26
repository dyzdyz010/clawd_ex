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

  test "renders dashboard with key sections", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")

    assert html =~ "Dashboard"
    assert html =~ "Agents"
    assert html =~ "Total Sessions"
    assert html =~ "Active Sessions"
    assert html =~ "Total Messages"
    assert html =~ "Today&#39;s Messages"
    assert html =~ "System Health"
    assert html =~ "Quick Actions"
    assert html =~ "New Chat"
    assert html =~ "Create Agent"
    assert html =~ "Recent Sessions"
    assert html =~ "Recent Messages"
  end

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
