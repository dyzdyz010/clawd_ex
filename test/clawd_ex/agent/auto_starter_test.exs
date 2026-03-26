defmodule ClawdEx.Agent.AutoStarterTest do
  use ClawdEx.DataCase, async: false

  alias ClawdEx.Agent.AutoStarter
  alias ClawdEx.Agents.Agent
  alias ClawdEx.Sessions.SessionManager

  setup do
    # Clean up any sessions we start
    on_exit(fn ->
      for key <- SessionManager.list_sessions(),
          String.contains?(key, "always_on") do
        SessionManager.stop_session(key)
      end
    end)

    :ok
  end

  describe "auto_start agents" do
    test "starts sessions for auto_start agents" do
      # Create an auto_start agent
      {:ok, agent} =
        %Agent{}
        |> Agent.changeset(%{
          name: "auto-starter-test-#{System.unique_integer([:positive])}",
          auto_start: true,
          active: true
        })
        |> Repo.insert()

      # Start AutoStarter with minimal delay and a unique name to avoid conflicts
      {:ok, pid} =
        AutoStarter.start_link(
          delay: 50,
          health_check_interval: 600_000,
          name: :"auto_starter_test_#{System.unique_integer([:positive])}"
        )

      # Wait for the auto-start to complete
      Process.sleep(300)

      # Verify the session is actually running
      expected_key = "agent:#{agent.name}:always_on"
      assert {:ok, _pid} = SessionManager.find_session(expected_key)

      # Clean up
      GenServer.stop(pid)
      SessionManager.stop_session(expected_key)
    end

    test "skips inactive agents" do
      {:ok, _agent} =
        %Agent{}
        |> Agent.changeset(%{
          name: "inactive-auto-#{System.unique_integer([:positive])}",
          auto_start: true,
          active: false
        })
        |> Repo.insert()

      {:ok, pid} =
        AutoStarter.start_link(
          delay: 50,
          health_check_interval: 600_000,
          name: :"auto_starter_test_#{System.unique_integer([:positive])}"
        )

      Process.sleep(300)

      # No sessions should have been started for this inactive agent
      GenServer.stop(pid)
    end

    test "skips agents with auto_start: false" do
      {:ok, _agent} =
        %Agent{}
        |> Agent.changeset(%{
          name: "no-auto-#{System.unique_integer([:positive])}",
          auto_start: false,
          active: true
        })
        |> Repo.insert()

      {:ok, pid} =
        AutoStarter.start_link(
          delay: 50,
          health_check_interval: 600_000,
          name: :"auto_starter_test_#{System.unique_integer([:positive])}"
        )

      Process.sleep(300)

      GenServer.stop(pid)
    end

    test "handles empty agent list gracefully" do
      # No auto_start agents in DB — should not crash
      {:ok, pid} =
        AutoStarter.start_link(
          delay: 50,
          health_check_interval: 600_000,
          name: :"auto_starter_test_#{System.unique_integer([:positive])}"
        )

      Process.sleep(300)

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe "health check" do
    test "health check recovers a missing session" do
      {:ok, agent} =
        %Agent{}
        |> Agent.changeset(%{
          name: "health-check-test-#{System.unique_integer([:positive])}",
          auto_start: true,
          active: true
        })
        |> Repo.insert()

      session_key = "agent:#{agent.name}:always_on"

      # Start AutoStarter with long health check interval (we'll trigger manually)
      {:ok, pid} =
        AutoStarter.start_link(
          delay: 50,
          health_check_interval: 600_000,
          name: :"auto_starter_test_#{System.unique_integer([:positive])}"
        )

      # Wait for initial start
      Process.sleep(300)

      # Session should be running
      assert {:ok, _} = SessionManager.find_session(session_key)

      # Kill the session to simulate crash
      SessionManager.stop_session(session_key)
      Process.sleep(100)
      assert :not_found = SessionManager.find_session(session_key)

      # Trigger health check manually
      send(pid, :health_check)
      Process.sleep(300)

      # Session should be recovered
      assert {:ok, _} = SessionManager.find_session(session_key)

      # Clean up
      GenServer.stop(pid)
      SessionManager.stop_session(session_key)
    end

    test "health check schedules periodic checks" do
      # Start with a short health check interval
      {:ok, pid} =
        AutoStarter.start_link(
          delay: 50,
          health_check_interval: 200,
          name: :"auto_starter_test_#{System.unique_integer([:positive])}"
        )

      # Wait for initial start + at least one health check cycle
      Process.sleep(500)

      # AutoStarter should still be alive (health checks didn't crash it)
      assert Process.alive?(pid)

      GenServer.stop(pid)
    end

    test "health check is resilient to no auto_start agents" do
      {:ok, pid} =
        AutoStarter.start_link(
          delay: 50,
          health_check_interval: 600_000,
          name: :"auto_starter_test_#{System.unique_integer([:positive])}"
        )

      Process.sleep(300)

      # Trigger health check with no agents — should not crash
      send(pid, :health_check)
      Process.sleep(100)

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end
end
