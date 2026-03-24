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

      # Start AutoStarter with minimal delay
      {:ok, pid} = AutoStarter.start_link(delay: 50)

      # Wait for the auto-start to complete
      Process.sleep(200)

      # Verify a session was started
      expected_key = "agent:#{agent.name}:always_on"
      started = AutoStarter.started_sessions()
      assert expected_key in started

      # Verify the session is actually running
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

      {:ok, pid} = AutoStarter.start_link(delay: 50)
      Process.sleep(200)

      started = AutoStarter.started_sessions()
      assert started == []

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

      {:ok, pid} = AutoStarter.start_link(delay: 50)
      Process.sleep(200)

      started = AutoStarter.started_sessions()
      assert started == []

      GenServer.stop(pid)
    end

    test "handles empty agent list gracefully" do
      # No auto_start agents in DB — should not crash
      {:ok, pid} = AutoStarter.start_link(delay: 50)
      Process.sleep(200)

      started = AutoStarter.started_sessions()
      assert started == []

      GenServer.stop(pid)
    end
  end
end
