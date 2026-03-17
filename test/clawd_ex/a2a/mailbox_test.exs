defmodule ClawdEx.A2A.MailboxTest do
  use ExUnit.Case, async: false

  alias ClawdEx.A2A.Mailbox

  setup do
    # Ensure infrastructure processes are alive (they may have crashed due to supervisor restarts)
    unless Process.whereis(ClawdEx.A2AMailboxRegistry) do
      Registry.start_link(keys: :unique, name: ClawdEx.A2AMailboxRegistry)
    end

    unless Process.whereis(ClawdEx.A2AMailboxSupervisor) do
      DynamicSupervisor.start_link(name: ClawdEx.A2AMailboxSupervisor, strategy: :one_for_one)
    end

    # Use a unique agent_id for each test to avoid conflicts
    agent_id = System.unique_integer([:positive])

    {:ok, pid} = Mailbox.ensure_started(agent_id)

    on_exit(fn ->
      if Process.alive?(pid) do
        # Use terminate_child to avoid triggering permanent restart / max_restarts
        DynamicSupervisor.terminate_child(ClawdEx.A2AMailboxSupervisor, pid)
      end
    end)

    %{agent_id: agent_id, pid: pid}
  end

  # ============================================================================
  # ensure_started
  # ============================================================================

  describe "ensure_started/1" do
    test "starts a mailbox for a new agent" do
      new_agent_id = System.unique_integer([:positive])
      assert {:ok, pid} = Mailbox.ensure_started(new_agent_id)
      assert Process.alive?(pid)

      on_exit(fn ->
        if Process.alive?(pid) do
          DynamicSupervisor.terminate_child(ClawdEx.A2AMailboxSupervisor, pid)
        end
      end)
    end

    test "returns existing mailbox if already started", %{agent_id: agent_id, pid: pid} do
      assert {:ok, ^pid} = Mailbox.ensure_started(agent_id)
    end
  end

  # ============================================================================
  # peek
  # ============================================================================

  describe "peek/1" do
    test "returns :empty for empty mailbox", %{agent_id: agent_id} do
      assert :empty = Mailbox.peek(agent_id)
    end

    test "returns first message without removing it", %{agent_id: agent_id} do
      deliver_message(agent_id, %{message_id: "msg-1", content: "First"})
      Process.sleep(50)

      assert {:ok, msg} = Mailbox.peek(agent_id)
      assert msg.message_id == "msg-1"

      # Peek again — message should still be there
      assert {:ok, msg2} = Mailbox.peek(agent_id)
      assert msg2.message_id == "msg-1"
    end

    test "returns :empty for non-existent mailbox" do
      assert :empty = Mailbox.peek(-99999)
    end
  end

  # ============================================================================
  # pop
  # ============================================================================

  describe "pop/1" do
    test "returns :empty for empty mailbox", %{agent_id: agent_id} do
      assert :empty = Mailbox.pop(agent_id)
    end

    test "removes and returns first message", %{agent_id: agent_id} do
      deliver_message(agent_id, %{message_id: "msg-pop-1", content: "First"})
      deliver_message(agent_id, %{message_id: "msg-pop-2", content: "Second"})
      Process.sleep(50)

      assert {:ok, msg} = Mailbox.pop(agent_id)
      assert msg.message_id == "msg-pop-1"

      # Second pop should return second message
      assert {:ok, msg2} = Mailbox.pop(agent_id)
      assert msg2.message_id == "msg-pop-2"

      # Third pop should be empty
      assert :empty = Mailbox.pop(agent_id)
    end

    test "returns :empty for non-existent mailbox" do
      assert :empty = Mailbox.pop(-99998)
    end
  end

  # ============================================================================
  # ack
  # ============================================================================

  describe "ack/2" do
    test "acknowledges a popped message", %{agent_id: agent_id} do
      deliver_message(agent_id, %{message_id: "msg-ack-1", content: "To ack"})
      Process.sleep(50)

      {:ok, _msg} = Mailbox.pop(agent_id)

      # ack should not crash
      assert :ok = Mailbox.ack(agent_id, "msg-ack-1")
    end

    test "returns :ok for non-existent mailbox" do
      assert :ok = Mailbox.ack(-99997, "nonexistent")
    end
  end

  # ============================================================================
  # count
  # ============================================================================

  describe "count/1" do
    test "returns 0 for empty mailbox", %{agent_id: agent_id} do
      assert 0 = Mailbox.count(agent_id)
    end

    test "returns correct count after messages delivered", %{agent_id: agent_id} do
      deliver_message(agent_id, %{message_id: "msg-c-1", content: "One"})
      deliver_message(agent_id, %{message_id: "msg-c-2", content: "Two"})
      deliver_message(agent_id, %{message_id: "msg-c-3", content: "Three"})
      Process.sleep(50)

      assert 3 = Mailbox.count(agent_id)
    end

    test "decreases after pop", %{agent_id: agent_id} do
      deliver_message(agent_id, %{message_id: "msg-d-1", content: "One"})
      deliver_message(agent_id, %{message_id: "msg-d-2", content: "Two"})
      Process.sleep(50)

      assert 2 = Mailbox.count(agent_id)

      Mailbox.pop(agent_id)
      assert 1 = Mailbox.count(agent_id)
    end

    test "returns 0 for non-existent mailbox" do
      assert 0 = Mailbox.count(-99996)
    end
  end

  # ============================================================================
  # list
  # ============================================================================

  describe "list/1" do
    test "returns empty list for empty mailbox", %{agent_id: agent_id} do
      assert [] = Mailbox.list(agent_id)
    end

    test "returns all pending messages", %{agent_id: agent_id} do
      deliver_message(agent_id, %{message_id: "msg-l-1", content: "First"})
      deliver_message(agent_id, %{message_id: "msg-l-2", content: "Second"})
      Process.sleep(50)

      messages = Mailbox.list(agent_id)
      assert length(messages) == 2
      ids = Enum.map(messages, & &1.message_id)
      assert "msg-l-1" in ids
      assert "msg-l-2" in ids
    end

    test "returns empty list for non-existent mailbox" do
      assert [] = Mailbox.list(-99995)
    end
  end

  # ============================================================================
  # PubSub message delivery
  # ============================================================================

  describe "PubSub message delivery" do
    test "receives messages via PubSub broadcast", %{agent_id: agent_id} do
      # Deliver via PubSub (same as Router does)
      Phoenix.PubSub.broadcast(
        ClawdEx.PubSub,
        "a2a:#{agent_id}",
        {:a2a_message, %{
          message_id: "pubsub-1",
          from_agent_id: 999,
          type: "notification",
          content: "Via PubSub",
          metadata: %{},
          reply_to: nil
        }}
      )

      Process.sleep(100)

      assert {:ok, msg} = Mailbox.peek(agent_id)
      assert msg.message_id == "pubsub-1"
      assert msg.content == "Via PubSub"
    end

    test "notifies agent_mailbox topic on message receipt", %{agent_id: agent_id} do
      Phoenix.PubSub.subscribe(ClawdEx.PubSub, "agent_mailbox:#{agent_id}")

      deliver_message(agent_id, %{message_id: "notify-1", content: "Notify"})

      assert_receive {:mailbox_message, ^agent_id, _msg}, 500
    end
  end

  # ============================================================================
  # Queue ordering (FIFO)
  # ============================================================================

  describe "FIFO ordering" do
    test "messages are returned in insertion order", %{agent_id: agent_id} do
      for i <- 1..5 do
        deliver_message(agent_id, %{message_id: "fifo-#{i}", content: "Message #{i}"})
        # Small delay to ensure ordering
        Process.sleep(10)
      end

      Process.sleep(50)

      messages = Mailbox.list(agent_id)
      ids = Enum.map(messages, & &1.message_id)
      assert ids == ["fifo-1", "fifo-2", "fifo-3", "fifo-4", "fifo-5"]
    end

    test "pop returns messages in FIFO order", %{agent_id: agent_id} do
      for i <- 1..3 do
        deliver_message(agent_id, %{message_id: "pop-fifo-#{i}", content: "M#{i}"})
        Process.sleep(10)
      end

      Process.sleep(50)

      {:ok, m1} = Mailbox.pop(agent_id)
      {:ok, m2} = Mailbox.pop(agent_id)
      {:ok, m3} = Mailbox.pop(agent_id)

      assert m1.message_id == "pop-fifo-1"
      assert m2.message_id == "pop-fifo-2"
      assert m3.message_id == "pop-fifo-3"
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp deliver_message(agent_id, msg_attrs) do
    msg =
      Map.merge(
        %{
          from_agent_id: 0,
          type: "notification",
          metadata: %{},
          reply_to: nil
        },
        msg_attrs
      )

    Phoenix.PubSub.broadcast(
      ClawdEx.PubSub,
      "a2a:#{agent_id}",
      {:a2a_message, msg}
    )
  end
end
