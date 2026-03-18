defmodule ClawdEx.Channels.ChannelDispatcherTest do
  use ClawdEx.DataCase, async: false

  alias ClawdEx.Channels.ChannelDispatcher

  setup do
    # Start the dispatcher (or reuse existing)
    case GenServer.whereis(ChannelDispatcher) do
      nil ->
        {:ok, pid} = ChannelDispatcher.start_link([])
        # Allow the GenServer to use the test's sandbox connection
        Ecto.Adapters.SQL.Sandbox.allow(ClawdEx.Repo, self(), pid)
        on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
        %{pid: pid}

      pid ->
        # Allow the existing GenServer to use the test's sandbox connection
        Ecto.Adapters.SQL.Sandbox.allow(ClawdEx.Repo, self(), pid)
        %{pid: pid}
    end
  end

  describe "init/1" do
    test "starts with empty sessions state", %{pid: pid} do
      state = :sys.get_state(pid)
      assert %{sessions: sessions} = state
      assert is_map(sessions)
    end
  end

  describe "register_session/4 and unregister_session/1" do
    test "registers a session", %{pid: pid} do
      ChannelDispatcher.register_session("test-session-1", "telegram", "chat_123", [])
      # Give the cast time to process
      :timer.sleep(100)

      state = :sys.get_state(pid)
      assert Map.has_key?(state.sessions, "test-session-1")

      session_info = state.sessions["test-session-1"]
      assert session_info.channel == "telegram"
      assert session_info.channel_id == "chat_123"
    end

    test "registers a session with reply_to option", %{pid: pid} do
      ChannelDispatcher.register_session("test-session-2", "telegram", "chat_456",
        reply_to: "msg_789"
      )

      :timer.sleep(100)

      state = :sys.get_state(pid)
      assert state.sessions["test-session-2"].reply_to == "msg_789"
    end

    test "unregisters a session", %{pid: pid} do
      ChannelDispatcher.register_session("test-session-3", "discord", "ch_001", [])
      :timer.sleep(100)

      ChannelDispatcher.unregister_session("test-session-3")
      :timer.sleep(100)

      state = :sys.get_state(pid)
      refute Map.has_key?(state.sessions, "test-session-3")
    end
  end

  describe "handle_info/2 for agent events" do
    test "ignores agent_segment for unknown session", %{pid: pid} do
      # Send an agent_segment for an unregistered session
      send(pid, {:agent_segment, "run-1", "hello", session_key: "nonexistent"})
      :timer.sleep(50)

      # Should not crash - process still alive
      assert Process.alive?(pid)
    end

    test "ignores agent_chunk events", %{pid: pid} do
      send(pid, {:agent_chunk, "run-1", "partial"})
      :timer.sleep(50)
      assert Process.alive?(pid)
    end

    test "ignores agent_status events", %{pid: pid} do
      send(pid, {:agent_status, "run-1", :running, %{}})
      :timer.sleep(50)
      assert Process.alive?(pid)
    end

    test "ignores unknown messages", %{pid: pid} do
      send(pid, {:totally_random, "data"})
      :timer.sleep(50)
      assert Process.alive?(pid)
    end

    test "ignores agent_segment with empty content", %{pid: pid} do
      # Register a session first
      ChannelDispatcher.register_session("test-empty", "telegram", "chat_999", [])
      :timer.sleep(100)

      # Send empty content - should not attempt to send
      send(pid, {:agent_segment, "run-1", "", session_key: "test-empty"})
      :timer.sleep(50)
      assert Process.alive?(pid)
    end

    test "ignores agent_segment with nil content", %{pid: pid} do
      ChannelDispatcher.register_session("test-nil", "telegram", "chat_888", [])
      :timer.sleep(100)

      send(pid, {:agent_segment, "run-1", nil, session_key: "test-nil"})
      :timer.sleep(50)
      assert Process.alive?(pid)
    end
  end

  describe "send_to_channel (via handle_info)" do
    test "unknown channel type doesn't crash", %{pid: pid} do
      # Register a session with unknown channel type
      ChannelDispatcher.register_session("test-unknown-ch", "sms", "phone_123", [])
      :timer.sleep(100)

      # Sending a segment should gracefully handle the unknown channel
      send(pid, {:agent_segment, "run-1", "hello sms", session_key: "test-unknown-ch"})
      :timer.sleep(50)

      assert Process.alive?(pid)
    end
  end
end
