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

  describe "mount" do
    test "renders A2A communication page", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/a2a")

      assert html =~ "A2A Communication"
    end

    test "displays stats section", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/a2a")

      assert html =~ "Total Messages"
      assert html =~ "Pending"
      assert html =~ "Delivered"
      assert html =~ "Processed"
      assert html =~ "Expired"
    end

    test "shows messages tab by default", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/a2a")

      assert html =~ "Messages"
      assert html =~ "Agent Registry"
    end

    test "shows empty state when no messages", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/a2a")

      assert html =~ "No messages found"
    end

    test "has filter controls", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/a2a")

      assert html =~ "Type"
      assert html =~ "Status"
    end
  end

  describe "events" do
    test "switch_tab to registry does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/a2a")

      view
      |> render_click("switch_tab", %{"tab" => "registry"})

      html = render(view)
      assert html =~ "A2A Communication"
    end

    test "switch_tab back to messages does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/a2a")

      view |> render_click("switch_tab", %{"tab" => "registry"})
      view |> render_click("switch_tab", %{"tab" => "messages"})

      html = render(view)
      assert html =~ "A2A Communication"
    end

    test "filter_type event does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/a2a")

      view
      |> render_click("filter_type", %{"type" => "request"})

      html = render(view)
      assert html =~ "A2A Communication"
    end

    test "filter_type all does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/a2a")

      view |> render_click("filter_type", %{"type" => "request"})
      view |> render_click("filter_type", %{"type" => "all"})

      html = render(view)
      assert html =~ "A2A Communication"
    end

    test "filter_status event does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/a2a")

      view
      |> render_click("filter_status", %{"status" => "pending"})

      html = render(view)
      assert html =~ "A2A Communication"
    end

    test "filter_status all does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/a2a")

      view |> render_click("filter_status", %{"status" => "delivered"})
      view |> render_click("filter_status", %{"status" => "all"})

      html = render(view)
      assert html =~ "A2A Communication"
    end

    test "filter_agent event does not crash", %{conn: conn} do
      agent = create_agent(%{name: "a2a-filter-agent", active: true})

      {:ok, view, _html} = live(conn, "/a2a")

      view
      |> render_click("filter_agent", %{"agent" => to_string(agent.id)})

      html = render(view)
      assert html =~ "A2A Communication"
    end
  end

  describe "with data" do
    test "displays A2A messages when they exist", %{conn: conn} do
      agent1 = create_agent(%{name: "sender-agent", active: true})
      agent2 = create_agent(%{name: "receiver-agent", active: true})
      create_a2a_message(agent1, agent2, %{content: "Hello from A2A test"})

      {:ok, _view, html} = live(conn, "/a2a")

      assert html =~ "Hello from A2A test"
    end
  end
end
