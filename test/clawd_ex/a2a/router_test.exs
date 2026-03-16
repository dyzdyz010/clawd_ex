defmodule ClawdEx.A2A.RouterTest do
  use ClawdEx.DataCase, async: false

  alias ClawdEx.A2A.Router
  alias ClawdEx.A2A.Message
  alias ClawdEx.Agents.Agent

  setup do
    {:ok, agent1} =
      %Agent{}
      |> Agent.changeset(%{name: "router-agent1-#{System.unique_integer([:positive])}"})
      |> Repo.insert()

    {:ok, agent2} =
      %Agent{}
      |> Agent.changeset(%{name: "router-agent2-#{System.unique_integer([:positive])}"})
      |> Repo.insert()

    # Clean up router registry state for this test
    on_exit(fn ->
      Router.unregister(agent1.id)
      Router.unregister(agent2.id)
    end)

    %{agent1: agent1, agent2: agent2}
  end

  # ============================================================================
  # Registration
  # ============================================================================

  describe "register/2 and unregister/1" do
    test "registers agent with capabilities", %{agent1: agent1} do
      assert :ok = Router.register(agent1.id, ["code_review", "testing"])

      {:ok, agents} = Router.discover()
      agent = Enum.find(agents, &(&1.agent_id == agent1.id))
      assert agent != nil
      assert agent.capabilities == ["code_review", "testing"]
    end

    test "registers agent without capabilities", %{agent1: agent1} do
      assert :ok = Router.register(agent1.id)

      {:ok, agents} = Router.discover()
      agent = Enum.find(agents, &(&1.agent_id == agent1.id))
      assert agent != nil
      assert agent.capabilities == []
    end

    test "unregisters agent", %{agent1: agent1} do
      Router.register(agent1.id, ["cap1"])
      assert :ok = Router.unregister(agent1.id)

      {:ok, agents} = Router.discover()
      agent = Enum.find(agents, &(&1.agent_id == agent1.id))
      assert agent == nil
    end
  end

  # ============================================================================
  # Discovery
  # ============================================================================

  describe "discover/1" do
    test "returns all registered agents", %{agent1: agent1, agent2: agent2} do
      Router.register(agent1.id, ["code"])
      Router.register(agent2.id, ["test"])

      {:ok, agents} = Router.discover()
      ids = Enum.map(agents, & &1.agent_id)
      assert agent1.id in ids
      assert agent2.id in ids
    end

    test "filters by capability", %{agent1: agent1, agent2: agent2} do
      Router.register(agent1.id, ["code_review", "refactoring"])
      Router.register(agent2.id, ["testing", "deployment"])

      {:ok, agents} = Router.discover(capability: "code")
      ids = Enum.map(agents, & &1.agent_id)
      assert agent1.id in ids
      refute agent2.id in ids
    end

    test "returns empty list when no agents match capability", %{agent1: agent1} do
      Router.register(agent1.id, ["code_review"])

      {:ok, agents} = Router.discover(capability: "nonexistent")
      assert agents == []
    end

    test "returns all when no capability filter", %{agent1: agent1} do
      Router.register(agent1.id, ["cap1"])

      {:ok, agents} = Router.discover()
      assert length(agents) >= 1
    end
  end

  # ============================================================================
  # send_message (async notification)
  # ============================================================================

  describe "send_message/4" do
    test "sends async message and returns message_id", %{agent1: agent1, agent2: agent2} do
      # Subscribe to receive the PubSub broadcast
      Phoenix.PubSub.subscribe(ClawdEx.PubSub, "a2a:#{agent2.id}")

      assert {:ok, message_id} =
               Router.send_message(agent1.id, agent2.id, "Hello agent2",
                 type: "notification",
                 metadata: %{"key" => "value"}
               )

      assert is_binary(message_id)
      assert String.length(message_id) > 0

      # Verify PubSub delivery
      assert_receive {:a2a_message, msg}, 500
      assert msg.from_agent_id == agent1.id
      assert msg.content == "Hello agent2"
      assert msg.type == "notification"
    end

    test "persists message to database", %{agent1: agent1, agent2: agent2} do
      {:ok, message_id} = Router.send_message(agent1.id, agent2.id, "Persisted msg")

      msg = Repo.get_by(Message, message_id: message_id)
      assert msg != nil
      assert msg.from_agent_id == agent1.id
      assert msg.to_agent_id == agent2.id
      assert msg.content == "Persisted msg"
      assert msg.type == "notification"
      # Status should be "delivered" after PubSub broadcast
      assert msg.status == "delivered"
    end

    test "uses default type 'notification'", %{agent1: agent1, agent2: agent2} do
      {:ok, message_id} = Router.send_message(agent1.id, agent2.id, "Default type")

      msg = Repo.get_by(Message, message_id: message_id)
      assert msg.type == "notification"
    end

    test "sends with custom TTL", %{agent1: agent1, agent2: agent2} do
      {:ok, message_id} =
        Router.send_message(agent1.id, agent2.id, "Short TTL", ttl: 60)

      msg = Repo.get_by(Message, message_id: message_id)
      assert msg.ttl_seconds == 60
    end
  end

  # ============================================================================
  # request/respond flow (sync)
  # ============================================================================

  describe "request/4 and respond/4" do
    test "completes sync request/response cycle", %{agent1: agent1, agent2: agent2} do
      # Subscribe so we can respond
      Phoenix.PubSub.subscribe(ClawdEx.PubSub, "a2a:#{agent2.id}")

      # Spawn a process to make the request (it blocks until response)
      caller = self()

      task =
        Task.async(fn ->
          result =
            Router.request(agent1.id, agent2.id, "What's 2+2?",
              timeout: 5_000
            )

          send(caller, {:request_result, result})
        end)

      # Wait for the request message to arrive at agent2
      assert_receive {:a2a_message, msg}, 1_000
      assert msg.type == "request"
      assert msg.content == "What's 2+2?"

      # Respond to the request
      {:ok, _resp_id} = Router.respond(msg.message_id, agent2.id, "4")

      # The caller should get the response
      assert_receive {:request_result, {:ok, "4"}}, 5_000

      Task.await(task)
    end

    test "request times out when no response", %{agent1: agent1, agent2: agent2} do
      result =
        Router.request(agent1.id, agent2.id, "No one listens",
          timeout: 200
        )

      assert {:error, :timeout} = result
    end
  end

  # ============================================================================
  # mark_processed
  # ============================================================================

  describe "mark_processed/1" do
    test "updates message status to processed", %{agent1: agent1, agent2: agent2} do
      {:ok, message_id} = Router.send_message(agent1.id, agent2.id, "To process")

      Router.mark_processed(message_id)
      # Give the cast time to complete
      Process.sleep(100)

      msg = Repo.get_by(Message, message_id: message_id)
      assert msg.status == "processed"
      assert msg.processed_at != nil
    end

    test "does not crash for non-existent message_id" do
      # Should not crash
      Router.mark_processed("nonexistent-id")
      Process.sleep(50)
    end
  end

  # ============================================================================
  # Message persistence
  # ============================================================================

  describe "message persistence" do
    test "stores metadata in message", %{agent1: agent1, agent2: agent2} do
      metadata = %{"priority" => "high", "tags" => ["urgent"]}

      {:ok, message_id} =
        Router.send_message(agent1.id, agent2.id, "With meta", metadata: metadata)

      msg = Repo.get_by(Message, message_id: message_id)
      assert msg.metadata == metadata
    end

    test "stores reply_to for responses", %{agent1: agent1, agent2: agent2} do
      Phoenix.PubSub.subscribe(ClawdEx.PubSub, "a2a:#{agent2.id}")

      # Spawn request in background
      spawn(fn ->
        Router.request(agent1.id, agent2.id, "Request", timeout: 2_000)
      end)

      assert_receive {:a2a_message, msg}, 1_000
      {:ok, resp_id} = Router.respond(msg.message_id, agent2.id, "Response")

      resp = Repo.get_by(Message, message_id: resp_id)
      assert resp.reply_to == msg.message_id
      assert resp.type == "response"
    end
  end
end
