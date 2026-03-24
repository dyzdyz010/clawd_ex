defmodule ClawdEx.ACP.SessionTest do
  use ClawdEx.DataCase, async: false

  alias ClawdEx.ACP.{Session, Registry, Event}

  setup do
    # Register mock backend
    :ok = Registry.register_backend("cli", ClawdEx.ACP.MockBackend)

    on_exit(fn ->
      Registry.unregister_backend("cli")
    end)

    :ok
  end

  describe "start/1 and lifecycle" do
    test "starts a new ACP session successfully" do
      session_key = "agent:test:acp:#{System.unique_integer([:positive])}"

      assert {:ok, pid} = Session.start(%{
        session_key: session_key,
        agent_id: "codex",
        label: "test-session"
      })

      assert is_pid(pid)

      # Give it time to ensure_session
      Process.sleep(100)

      assert {:ok, status} = Session.get_status(session_key)
      assert status.session_key == session_key
      assert status.agent_id == "codex"
      assert status.label == "test-session"
      assert status.status in [:idle, :running, :done]

      # Cleanup
      Session.close(session_key)
    end

    test "close/1 terminates the session" do
      session_key = "agent:test:acp:close-#{System.unique_integer([:positive])}"

      {:ok, pid} = Session.start(%{
        session_key: session_key,
        agent_id: "codex"
      })

      Process.sleep(100)
      assert :ok = Session.close(session_key)

      # Process should be dead after close
      Process.sleep(50)
      refute Process.alive?(pid)
    end

    test "close/1 returns :ok for non-existent session" do
      assert :ok = Session.close("nonexistent:session:key")
    end

    test "get_status/1 returns error for non-existent session" do
      assert {:error, :not_found} = Session.get_status("nonexistent:session:key")
    end
  end

  describe "run_turn/3" do
    test "runs a turn and receives events" do
      session_key = "agent:test:acp:turn-#{System.unique_integer([:positive])}"

      # Subscribe to events
      Phoenix.PubSub.subscribe(ClawdEx.PubSub, "acp:session:#{session_key}")

      {:ok, _pid} = Session.start(%{
        session_key: session_key,
        agent_id: "codex",
        label: "turn-test"
      })

      # Wait for ensure_session
      Process.sleep(200)

      assert :ok = Session.run_turn(session_key, "Hello ACP!")

      # Should receive text_delta and done events
      assert_receive {:acp_event, ^session_key, %Event{type: :text_delta}}, 3_000
      assert_receive {:acp_event, ^session_key, %Event{type: :done}}, 3_000

      Session.close(session_key)
    end

    test "rejects concurrent turns" do
      # Override the cli backend with the slow mock for this test
      :ok = Registry.register_backend("cli", ClawdEx.ACP.SlowMockBackend)

      session_key = "agent:test:acp:concurrent-#{System.unique_integer([:positive])}"

      {:ok, _pid} = Session.start(%{
        session_key: session_key,
        agent_id: "codex"
      })

      Process.sleep(200)

      # Start first turn (slow backend will take 5s)
      assert :ok = Session.run_turn(session_key, "slow task")

      # Give it time to transition to :running
      Process.sleep(100)

      # Second turn should be rejected
      assert {:error, :already_running} = Session.run_turn(session_key, "second task")

      Session.close(session_key)

      # Restore normal mock backend
      :ok = Registry.register_backend("cli", ClawdEx.ACP.MockBackend)
    end
  end

  describe "list_sessions/0" do
    test "returns list of active sessions" do
      key1 = "agent:test:acp:list1-#{System.unique_integer([:positive])}"
      key2 = "agent:test:acp:list2-#{System.unique_integer([:positive])}"

      {:ok, _} = Session.start(%{session_key: key1, agent_id: "codex", label: "s1"})
      {:ok, _} = Session.start(%{session_key: key2, agent_id: "claude", label: "s2"})

      Process.sleep(100)

      sessions = Session.list_sessions()
      session_keys = Enum.map(sessions, & &1.session_key)

      assert key1 in session_keys
      assert key2 in session_keys

      Session.close(key1)
      Session.close(key2)
    end
  end

  describe "cancel/1" do
    test "cancels a running turn" do
      session_key = "agent:test:acp:cancel-#{System.unique_integer([:positive])}"

      {:ok, _} = Session.start(%{
        session_key: session_key,
        agent_id: "codex"
      })

      Process.sleep(200)
      assert :ok = Session.cancel(session_key)

      Session.close(session_key)
    end

    test "cancel on non-existent session returns error" do
      assert {:error, :not_found} = Session.cancel("nonexistent:key")
    end
  end

  describe "parent session notification" do
    test "broadcasts completion to parent session" do
      parent_key = "agent:test:parent:#{System.unique_integer([:positive])}"
      session_key = "agent:test:acp:notify-#{System.unique_integer([:positive])}"

      # Subscribe to parent session PubSub
      Phoenix.PubSub.subscribe(ClawdEx.PubSub, "session:#{parent_key}")

      {:ok, _pid} = Session.start(%{
        session_key: session_key,
        agent_id: "codex",
        parent_session_key: parent_key,
        label: "notify-test"
      })

      Process.sleep(200)

      # Run a turn
      Session.run_turn(session_key, "test task")

      # Should receive completion via PubSub
      assert_receive {:subagent_completed, completion}, 5_000
      assert completion.childSessionKey == session_key
      assert completion.label == "notify-test"
      assert completion.runtime == "acp"
      assert completion.status == :completed

      Session.close(session_key)
    end
  end
end
