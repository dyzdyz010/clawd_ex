defmodule ClawdExWeb.Api.A2AControllerTest do
  use ClawdExWeb.ConnCase, async: false

  alias ClawdEx.Repo
  alias ClawdEx.Agents.Agent
  alias ClawdEx.A2A.{Router, Message}

  setup %{conn: conn} do
    conn = put_req_header(conn, "content-type", "application/json")

    {:ok, agent1} =
      %Agent{}
      |> Agent.changeset(%{name: "api-a2a-agent1-#{System.unique_integer([:positive])}"})
      |> Repo.insert()

    {:ok, agent2} =
      %Agent{}
      |> Agent.changeset(%{name: "api-a2a-agent2-#{System.unique_integer([:positive])}"})
      |> Repo.insert()

    Router.register(agent1.id, ["coding", "review"])
    Router.register(agent2.id, ["testing"])

    on_exit(fn ->
      Router.unregister(agent1.id)
      Router.unregister(agent2.id)
    end)

    {:ok, conn: conn, agent1: agent1, agent2: agent2}
  end

  # ============================================================================
  # POST /api/v1/a2a/messages
  # ============================================================================

  describe "POST /api/v1/a2a/messages" do
    test "sends a message successfully", %{conn: conn, agent1: agent1, agent2: agent2} do
      conn =
        post(conn, "/api/v1/a2a/messages", %{
          from_agent_id: agent1.id,
          to_agent_id: agent2.id,
          content: "Hello via API",
          type: "notification",
          priority: 3,
          metadata: %{"key" => "value"}
        })

      body = json_response(conn, 201)
      assert body["data"]["message_id"]
      assert body["data"]["from_agent_id"] == agent1.id
      assert body["data"]["to_agent_id"] == agent2.id
      assert body["data"]["priority"] == 3
      assert body["data"]["type"] == "notification"

      # Verify persisted in DB
      msg = Repo.get_by(Message, message_id: body["data"]["message_id"])
      assert msg != nil
      assert msg.priority == 3
      assert msg.content == "Hello via API"
    end

    test "uses default priority and type", %{conn: conn, agent1: agent1, agent2: agent2} do
      conn =
        post(conn, "/api/v1/a2a/messages", %{
          from_agent_id: agent1.id,
          to_agent_id: agent2.id,
          content: "Default priority"
        })

      body = json_response(conn, 201)
      assert body["data"]["priority"] == 5
      assert body["data"]["type"] == "notification"
    end

    test "sends delegation type message", %{conn: conn, agent1: agent1, agent2: agent2} do
      conn =
        post(conn, "/api/v1/a2a/messages", %{
          from_agent_id: agent1.id,
          to_agent_id: agent2.id,
          content: "Please review PR",
          type: "delegation",
          priority: 1
        })

      body = json_response(conn, 201)
      assert body["data"]["type"] == "delegation"
      assert body["data"]["priority"] == 1
    end

    test "returns error without from_agent_id", %{conn: conn, agent2: agent2} do
      conn =
        post(conn, "/api/v1/a2a/messages", %{
          to_agent_id: agent2.id,
          content: "Missing from"
        })

      body = json_response(conn, 400)
      assert body["error"]["message"] =~ "from_agent_id"
    end

    test "returns error without to_agent_id", %{conn: conn, agent1: agent1} do
      conn =
        post(conn, "/api/v1/a2a/messages", %{
          from_agent_id: agent1.id,
          content: "Missing to"
        })

      body = json_response(conn, 400)
      assert body["error"]["message"] =~ "to_agent_id"
    end

    test "returns error without content", %{conn: conn, agent1: agent1, agent2: agent2} do
      conn =
        post(conn, "/api/v1/a2a/messages", %{
          from_agent_id: agent1.id,
          to_agent_id: agent2.id
        })

      body = json_response(conn, 400)
      assert body["error"]["message"] =~ "content"
    end

    test "returns error for invalid type", %{conn: conn, agent1: agent1, agent2: agent2} do
      conn =
        post(conn, "/api/v1/a2a/messages", %{
          from_agent_id: agent1.id,
          to_agent_id: agent2.id,
          content: "Bad type",
          type: "invalid_type"
        })

      body = json_response(conn, 400)
      assert body["error"]["message"] =~ "Invalid type"
    end
  end

  # ============================================================================
  # GET /api/v1/a2a/agents
  # ============================================================================

  describe "GET /api/v1/a2a/agents" do
    test "lists all registered agents", %{conn: conn, agent1: agent1, agent2: agent2} do
      conn = get(conn, "/api/v1/a2a/agents")

      body = json_response(conn, 200)
      assert is_list(body["data"])
      assert body["total"] >= 2

      ids = Enum.map(body["data"], & &1["agent_id"])
      assert agent1.id in ids
      assert agent2.id in ids
    end

    test "filters by capability", %{conn: conn, agent1: agent1, agent2: agent2} do
      conn = get(conn, "/api/v1/a2a/agents?capability=coding")

      body = json_response(conn, 200)
      ids = Enum.map(body["data"], & &1["agent_id"])
      assert agent1.id in ids
      refute agent2.id in ids
    end

    test "returns agent capabilities", %{conn: conn, agent1: agent1} do
      conn = get(conn, "/api/v1/a2a/agents")

      body = json_response(conn, 200)
      a1 = Enum.find(body["data"], &(&1["agent_id"] == agent1.id))
      assert a1["capabilities"] == ["coding", "review"]
    end

    test "returns empty when no agents match capability", %{conn: conn} do
      conn = get(conn, "/api/v1/a2a/agents?capability=nonexistent")

      body = json_response(conn, 200)
      assert body["total"] == 0
      assert body["data"] == []
    end
  end

  # ============================================================================
  # GET /api/v1/a2a/messages/:agent_id
  # ============================================================================

  describe "GET /api/v1/a2a/messages/:agent_id" do
    test "returns inbox messages for agent", %{conn: conn, agent1: agent1, agent2: agent2} do
      # Send some messages to agent2
      Router.send_message(agent1.id, agent2.id, "Message 1", priority: 3)
      Router.send_message(agent1.id, agent2.id, "Message 2", priority: 1)
      Router.send_message(agent1.id, agent2.id, "Message 3", priority: 5)

      # Wait for delivery
      Process.sleep(50)

      # Messages get delivered status, so query delivered
      conn = get(conn, "/api/v1/a2a/messages/#{agent2.id}?status=delivered")

      body = json_response(conn, 200)
      assert length(body["data"]) >= 3

      # Should be sorted by priority (ascending)
      priorities = Enum.map(body["data"], & &1["priority"])
      assert priorities == Enum.sort(priorities)
    end

    test "filters by status", %{conn: conn, agent1: agent1, agent2: agent2} do
      # Send a message (will be "delivered" after broadcast)
      {:ok, msg_id} = Router.send_message(agent1.id, agent2.id, "To process")
      Process.sleep(50)

      # Mark as processed
      Router.mark_processed(msg_id)
      Process.sleep(100)

      conn_processed = get(conn, "/api/v1/a2a/messages/#{agent2.id}?status=processed")
      body = json_response(conn_processed, 200)

      processed_ids = Enum.map(body["data"], & &1["message_id"])
      assert msg_id in processed_ids
    end

    test "respects limit parameter", %{conn: conn, agent1: agent1, agent2: agent2} do
      # Send 5 messages
      for i <- 1..5 do
        Router.send_message(agent1.id, agent2.id, "Msg #{i}")
      end

      Process.sleep(50)

      conn = get(conn, "/api/v1/a2a/messages/#{agent2.id}?status=delivered&limit=2")
      body = json_response(conn, 200)
      assert length(body["data"]) <= 2
    end

    test "includes mailbox_pending count", %{conn: conn, agent2: agent2} do
      conn = get(conn, "/api/v1/a2a/messages/#{agent2.id}")
      body = json_response(conn, 200)
      assert is_integer(body["mailbox_pending"])
    end

    test "returns message fields", %{conn: conn, agent1: agent1, agent2: agent2} do
      Router.send_message(agent1.id, agent2.id, "Detailed message",
        priority: 2,
        metadata: %{"tag" => "test"}
      )

      Process.sleep(50)

      conn = get(conn, "/api/v1/a2a/messages/#{agent2.id}?status=delivered")
      body = json_response(conn, 200)

      msg = Enum.find(body["data"], &(&1["content"] == "Detailed message"))
      assert msg != nil
      assert msg["priority"] == 2
      assert msg["metadata"]["tag"] == "test"
      assert msg["from_agent_id"] == agent1.id
      assert msg["to_agent_id"] == agent2.id
      assert msg["type"] == "notification"
      assert msg["message_id"]
      assert msg["inserted_at"]
    end
  end
end
