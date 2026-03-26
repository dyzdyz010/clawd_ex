defmodule ClawdExWeb.A2ALiveTest do
  use ClawdExWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  alias ClawdEx.Repo
  alias ClawdEx.Agents.Agent
  alias ClawdEx.A2A.Message, as: A2AMessage

  defp create_agent(attrs \\ %{}) do
    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(Map.merge(%{name: "test-agent-#{System.unique_integer([:positive])}"}, attrs))
      |> Repo.insert()

    agent
  end

  defp create_a2a_message(from_agent, to_agent, attrs \\ %{}) do
    {:ok, msg} =
      %A2AMessage{}
      |> A2AMessage.changeset(
        Map.merge(
          %{
            message_id: A2AMessage.generate_id(),
            type: "request",
            content: "Test A2A message",
            from_agent_id: from_agent.id,
            to_agent_id: to_agent.id,
            status: "pending"
          },
          attrs
        )
      )
      |> Repo.insert()

    msg
  end

  test "renders A2A page with key elements", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/a2a")

    assert html =~ "A2A Communication"
    assert html =~ "Total Messages"
    assert html =~ "Pending"
    assert html =~ "Delivered"
    assert html =~ "Processed"
    assert html =~ "Expired"
    assert html =~ "Messages"
    assert html =~ "Agent Registry"
    assert html =~ "No messages found"
    assert html =~ "Type"
    assert html =~ "Status"
  end

  test "tab switching works", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/a2a")

    html = view |> render_click("switch_tab", %{"tab" => "registry"})
    assert html =~ "A2A Communication"

    html = view |> render_click("switch_tab", %{"tab" => "messages"})
    assert html =~ "A2A Communication"
  end

  test "filter events do not crash", %{conn: conn} do
    agent = create_agent(%{name: "a2a-filter-agent", active: true})
    {:ok, view, _html} = live(conn, "/a2a")

    for {event, params} <- [
          {"filter_type", %{"type" => "request"}},
          {"filter_type", %{"type" => "all"}},
          {"filter_status", %{"status" => "pending"}},
          {"filter_status", %{"status" => "all"}},
          {"filter_agent", %{"agent" => to_string(agent.id)}}
        ] do
      html = view |> render_click(event, params)
      assert html =~ "A2A Communication"
    end
  end

  test "displays A2A messages when they exist", %{conn: conn} do
    agent1 = create_agent(%{name: "sender-agent", active: true})
    agent2 = create_agent(%{name: "receiver-agent", active: true})
    create_a2a_message(agent1, agent2, %{content: "Hello from A2A test"})

    {:ok, _view, html} = live(conn, "/a2a")

    assert html =~ "Hello from A2A test"
  end
end
