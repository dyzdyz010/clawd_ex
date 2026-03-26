defmodule ClawdExWeb.SessionDetailLiveTest do
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

  defp create_session(agent, attrs \\ %{}) do
    {:ok, session} =
      %Session{}
      |> Session.changeset(
        Map.merge(
          %{
            session_key: "test:session:#{System.unique_integer([:positive])}",
            channel: "test",
            agent_id: agent.id,
            state: :active,
            last_activity_at: DateTime.utc_now()
          },
          attrs
        )
      )
      |> Repo.insert()

    session
  end

  defp create_message(session, attrs \\ %{}) do
    {:ok, message} =
      %Message{}
      |> Message.changeset(
        Map.merge(%{role: :user, content: "Test message content", session_id: session.id}, attrs)
      )
      |> Repo.insert()

    message
  end

  test "renders session detail with key sections", %{conn: conn} do
    agent = create_agent(%{name: "detail-test-agent"})
    session = create_session(agent)

    {:ok, _view, html} = live(conn, "/sessions/#{session.id}")

    assert html =~ session.session_key
    assert html =~ "Session Info"
    assert html =~ "detail-test-agent"
    assert html =~ "Messages"
    assert html =~ "No messages in this session"
  end

  test "displays messages with count", %{conn: conn} do
    agent = create_agent()
    session = create_session(agent)
    create_message(session, %{content: "Hello from test"})
    create_message(session, %{role: :assistant, content: "Response from assistant"})

    {:ok, _view, html} = live(conn, "/sessions/#{session.id}")

    assert html =~ "Hello from test"
    assert html =~ "Response from assistant"
    assert html =~ "Messages (2)"
  end

  test "delete_message removes a message", %{conn: conn} do
    agent = create_agent()
    session = create_session(agent)
    message = create_message(session, %{content: "Message to delete"})

    {:ok, view, _html} = live(conn, "/sessions/#{session.id}")

    view |> render_click("delete_message", %{"id" => to_string(message.id)})

    html = render(view)
    refute html =~ "Message to delete"
    assert html =~ "Message deleted"
  end
end
