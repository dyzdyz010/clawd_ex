defmodule ClawdEx.A2A.MailboxTest do
  use ClawdEx.DataCase, async: false

  alias ClawdEx.A2A.Mailbox
  alias ClawdEx.Agents.Agent

  setup do
    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{name: "mailbox-agent-#{System.unique_integer([:positive])}"})
      |> Repo.insert()

    {:ok, _pid} = Mailbox.ensure_started(agent.id)

    on_exit(fn ->
      # Clean up: stop the mailbox
      case Registry.lookup(ClawdEx.A2AMailboxRegistry, agent.id) do
        [{pid, _}] -> GenServer.stop(pid, :normal)
        [] -> :ok
      end
    end)

    %{agent: agent}
  end

  # ============================================================================
  # Priority Ordering
  # ============================================================================

  describe "priority ordering" do
    test "messages are returned highest priority first (lowest number)", %{agent: agent} do
      # Send messages with different priorities via PubSub
      send_to_mailbox(agent.id, %{
        message_id: "low-priority",
        from_agent_id: 999,
        type: "notification",
        content: "Low priority",
        metadata: %{},
        reply_to: nil,
        priority: 10
      })

      send_to_mailbox(agent.id, %{
        message_id: "urgent",
        from_agent_id: 999,
        type: "notification",
        content: "Urgent",
        metadata: %{},
        reply_to: nil,
        priority: 1
      })

      send_to_mailbox(agent.id, %{
        message_id: "normal",
        from_agent_id: 999,
        type: "notification",
        content: "Normal",
        metadata: %{},
        reply_to: nil,
        priority: 5
      })

      # Allow time for messages to be processed
      Process.sleep(50)

      # Pop should return urgent (1) first
      assert {:ok, msg1} = Mailbox.pop(agent.id)
      assert msg1.message_id == "urgent"

      # Then normal (5)
      assert {:ok, msg2} = Mailbox.pop(agent.id)
      assert msg2.message_id == "normal"

      # Then low (10)
      assert {:ok, msg3} = Mailbox.pop(agent.id)
      assert msg3.message_id == "low-priority"

      # Empty
      assert :empty = Mailbox.pop(agent.id)
    end

    test "same priority messages maintain FIFO order", %{agent: agent} do
      send_to_mailbox(agent.id, %{
        message_id: "first",
        from_agent_id: 999,
        type: "notification",
        content: "First",
        metadata: %{},
        reply_to: nil,
        priority: 5
      })

      send_to_mailbox(agent.id, %{
        message_id: "second",
        from_agent_id: 999,
        type: "notification",
        content: "Second",
        metadata: %{},
        reply_to: nil,
        priority: 5
      })

      send_to_mailbox(agent.id, %{
        message_id: "third",
        from_agent_id: 999,
        type: "notification",
        content: "Third",
        metadata: %{},
        reply_to: nil,
        priority: 5
      })

      Process.sleep(50)

      assert {:ok, msg1} = Mailbox.pop(agent.id)
      assert msg1.message_id == "first"

      assert {:ok, msg2} = Mailbox.pop(agent.id)
      assert msg2.message_id == "second"

      assert {:ok, msg3} = Mailbox.pop(agent.id)
      assert msg3.message_id == "third"
    end

    test "peek returns highest priority without removing", %{agent: agent} do
      send_to_mailbox(agent.id, %{
        message_id: "low",
        from_agent_id: 999,
        type: "notification",
        content: "Low",
        metadata: %{},
        reply_to: nil,
        priority: 10
      })

      send_to_mailbox(agent.id, %{
        message_id: "high",
        from_agent_id: 999,
        type: "notification",
        content: "High",
        metadata: %{},
        reply_to: nil,
        priority: 1
      })

      Process.sleep(50)

      assert {:ok, msg} = Mailbox.peek(agent.id)
      assert msg.message_id == "high"

      # Peek again — should still be there
      assert {:ok, msg2} = Mailbox.peek(agent.id)
      assert msg2.message_id == "high"

      # Count should still be 2
      assert Mailbox.count(agent.id) == 2
    end

    test "list returns messages in priority order", %{agent: agent} do
      send_to_mailbox(agent.id, %{
        message_id: "p10",
        from_agent_id: 999,
        type: "notification",
        content: "p10",
        metadata: %{},
        reply_to: nil,
        priority: 10
      })

      send_to_mailbox(agent.id, %{
        message_id: "p1",
        from_agent_id: 999,
        type: "notification",
        content: "p1",
        metadata: %{},
        reply_to: nil,
        priority: 1
      })

      send_to_mailbox(agent.id, %{
        message_id: "p5",
        from_agent_id: 999,
        type: "notification",
        content: "p5",
        metadata: %{},
        reply_to: nil,
        priority: 5
      })

      Process.sleep(50)

      messages = Mailbox.list(agent.id)
      ids = Enum.map(messages, & &1.message_id)
      assert ids == ["p1", "p5", "p10"]
    end

    test "default priority is 5 when not provided", %{agent: agent} do
      send_to_mailbox(agent.id, %{
        message_id: "no-priority",
        from_agent_id: 999,
        type: "notification",
        content: "No priority set",
        metadata: %{},
        reply_to: nil
        # No priority field
      })

      send_to_mailbox(agent.id, %{
        message_id: "urgent",
        from_agent_id: 999,
        type: "notification",
        content: "Urgent",
        metadata: %{},
        reply_to: nil,
        priority: 1
      })

      Process.sleep(50)

      # Urgent should come first (priority 1 < default 5)
      assert {:ok, msg} = Mailbox.pop(agent.id)
      assert msg.message_id == "urgent"
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp send_to_mailbox(agent_id, msg) do
    Phoenix.PubSub.broadcast(
      ClawdEx.PubSub,
      "a2a:#{agent_id}",
      {:a2a_message, msg}
    )
    # Small delay to ensure message is received
    Process.sleep(10)
  end
end
