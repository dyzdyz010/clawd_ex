defmodule ClawdEx.Sessions.SessionManagerTest do
  @moduledoc """
  Tests for SessionManager (DynamicSupervisor).

  Because SessionManager is started by the application supervisor,
  we test against the running instance. SessionWorker children need
  a database-backed session + AgentLoop, so we use DataCase (non-async)
  and rely on the sandbox for isolation.
  """
  use ClawdEx.DataCase, async: false

  alias ClawdEx.Sessions.SessionManager

  # Unique key per test to avoid collisions
  defp unique_key, do: "test_session_#{:erlang.unique_integer([:positive])}"

  describe "start_session/1" do
    test "starts a new session worker and returns {:ok, pid}" do
      key = unique_key()
      assert {:ok, pid} = SessionManager.start_session(session_key: key)
      assert is_pid(pid)
      assert Process.alive?(pid)

      # Cleanup
      SessionManager.stop_session(key)
    end

    test "returns existing pid when session already running" do
      key = unique_key()
      {:ok, pid1} = SessionManager.start_session(session_key: key)
      {:ok, pid2} = SessionManager.start_session(session_key: key)

      assert pid1 == pid2

      SessionManager.stop_session(key)
    end
  end

  describe "find_session/1" do
    test "returns {:ok, pid} for a running session" do
      key = unique_key()
      {:ok, pid} = SessionManager.start_session(session_key: key)

      assert {:ok, ^pid} = SessionManager.find_session(key)

      SessionManager.stop_session(key)
    end

    test "returns :not_found for non-existent session" do
      assert :not_found = SessionManager.find_session("nonexistent_#{:rand.uniform(999_999)}")
    end
  end

  describe "stop_session/1" do
    test "terminates a running session" do
      key = unique_key()
      {:ok, pid} = SessionManager.start_session(session_key: key)
      assert Process.alive?(pid)

      assert :ok = SessionManager.stop_session(key)
      # Give a moment for termination
      Process.sleep(50)
      refute Process.alive?(pid)
    end

    test "returns error for non-existent session" do
      assert {:error, :not_found} = SessionManager.stop_session("nonexistent_#{:rand.uniform(999_999)}")
    end
  end

  describe "list_sessions/0" do
    test "includes started sessions" do
      key = unique_key()
      {:ok, _pid} = SessionManager.start_session(session_key: key)

      sessions = SessionManager.list_sessions()
      assert key in sessions

      SessionManager.stop_session(key)
    end

    test "does not include stopped sessions" do
      key = unique_key()
      {:ok, _pid} = SessionManager.start_session(session_key: key)
      SessionManager.stop_session(key)
      Process.sleep(50)

      sessions = SessionManager.list_sessions()
      refute key in sessions
    end
  end
end
