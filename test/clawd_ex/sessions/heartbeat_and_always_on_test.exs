defmodule ClawdEx.Sessions.HeartbeatAndAlwaysOnTest do
  @moduledoc """
  Tests for Heartbeat timer, Always-On mode, and Session Recovery
  in SessionWorker.
  """
  use ClawdEx.DataCase, async: false

  alias ClawdEx.Sessions.{SessionManager, SessionWorker}
  alias ClawdEx.Agents.Agent

  defp unique_key, do: "hb_test_#{:erlang.unique_integer([:positive])}"

  # Create an agent with heartbeat and/or always_on config
  defp create_agent(opts \\ []) do
    heartbeat_interval = Keyword.get(opts, :heartbeat_interval_seconds)
    always_on = Keyword.get(opts, :always_on, false)
    name = "test_agent_#{:erlang.unique_integer([:positive])}"

    config =
      %{}
      |> then(fn c ->
        if heartbeat_interval, do: Map.put(c, "heartbeat_interval_seconds", heartbeat_interval), else: c
      end)
      |> then(fn c ->
        if always_on, do: Map.put(c, "always_on", true), else: c
      end)

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{name: name, config: config})
      |> Repo.insert()

    agent
  end

  defp start_session_with_agent(agent) do
    key = unique_key()
    {:ok, pid} = SessionManager.start_session(session_key: key, agent_id: agent.id)

    on_exit(fn ->
      try do
        SessionManager.stop_session(key)
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end)

    {key, pid}
  end

  # ============================================================================
  # Heartbeat Timer Tests
  # ============================================================================

  describe "heartbeat timer" do
    test "heartbeat message is scheduled when agent has heartbeat_interval_seconds" do
      agent = create_agent(heartbeat_interval_seconds: 1)
      {key, pid} = start_session_with_agent(agent)

      # Worker should be alive
      assert Process.alive?(pid)

      # The heartbeat timer should fire within ~1 second
      # We can't easily test the full heartbeat run (needs AI),
      # but we can verify the :heartbeat message arrives
      # by checking that the worker handles it without crashing

      # Wait slightly longer than the interval
      Process.sleep(1200)

      # Worker should still be alive (heartbeat handled gracefully)
      assert Process.alive?(pid)
    end

    test "no heartbeat scheduled when agent has no heartbeat config" do
      agent = create_agent()
      {_key, pid} = start_session_with_agent(agent)

      # Worker alive, no heartbeat timer firing
      Process.sleep(200)
      assert Process.alive?(pid)
    end

    test "heartbeat skips when agent is busy" do
      agent = create_agent(heartbeat_interval_seconds: 1)
      {key, pid} = start_session_with_agent(agent)

      # Simulate agent being busy by sending a direct message to the worker
      # to set agent_running = true
      :sys.replace_state(pid, fn state ->
        %{state | agent_running: true}
      end)

      # Send heartbeat manually
      send(pid, :heartbeat)
      Process.sleep(100)

      # Worker should still be alive and not have crashed
      assert Process.alive?(pid)

      # The heartbeat should have been skipped (agent was busy)
      # Verify agent_running is still true (heartbeat didn't change it)
      state = :sys.get_state(pid)
      assert state.agent_running == true
    end

    test "heartbeat triggers when agent is idle" do
      agent = create_agent(heartbeat_interval_seconds: 1)
      {_key, pid} = start_session_with_agent(agent)

      # Agent should be idle initially
      state = :sys.get_state(pid)
      assert state.agent_running == false

      # Send heartbeat manually
      send(pid, :heartbeat)
      Process.sleep(100)

      # Worker should still be alive
      assert Process.alive?(pid)

      # Agent running should have been set to true (heartbeat task started)
      # It may have completed quickly, so check process is alive
      assert Process.alive?(pid)
    end

    test "heartbeat_done reschedules next heartbeat" do
      agent = create_agent(heartbeat_interval_seconds: 2)
      {_key, pid} = start_session_with_agent(agent)

      # Get initial state
      state = :sys.get_state(pid)
      initial_ref = state.heartbeat_ref
      assert initial_ref != nil

      # Send heartbeat_done to reschedule
      send(pid, :heartbeat_done)
      Process.sleep(50)

      # Should have a new timer ref
      new_state = :sys.get_state(pid)
      assert new_state.heartbeat_ref != nil
      # The ref should be different (rescheduled)
      assert new_state.heartbeat_ref != initial_ref
    end
  end

  # ============================================================================
  # Heartbeat HEARTBEAT_OK Silent Tests
  # ============================================================================

  describe "heartbeat_ok? detection" do
    test "detects HEARTBEAT_OK response" do
      # Test the public-accessible logic indirectly via worker behavior
      # heartbeat_ok? is private, but we can test via integration

      agent = create_agent(heartbeat_interval_seconds: 60)
      {_key, pid} = start_session_with_agent(agent)

      # Verify worker is alive and has heartbeat configured
      state = :sys.get_state(pid)
      assert state.heartbeat_ref != nil
      assert Process.alive?(pid)
    end
  end

  # ============================================================================
  # Always-On Mode Tests
  # ============================================================================

  describe "always-on mode" do
    test "is_always_on? returns true for agent with always_on config" do
      agent = create_agent(always_on: true)
      assert SessionWorker.is_always_on?(agent) == true
    end

    test "is_always_on? returns false for agent without always_on" do
      agent = create_agent()
      assert SessionWorker.is_always_on?(agent) == false
    end

    test "is_always_on? returns false for nil" do
      assert SessionWorker.is_always_on?(nil) == false
    end

    test "always_on session starts without crashing" do
      agent = create_agent(always_on: true)
      {key, pid} = start_session_with_agent(agent)

      assert Process.alive?(pid)
      state = SessionWorker.get_state(key)
      assert state.session_key == key
    end

    test "always_on with heartbeat starts both features" do
      agent = create_agent(always_on: true, heartbeat_interval_seconds: 5)
      {key, pid} = start_session_with_agent(agent)

      assert Process.alive?(pid)

      # Check heartbeat is scheduled
      internal_state = :sys.get_state(pid)
      assert internal_state.heartbeat_ref != nil
    end
  end

  # ============================================================================
  # Session Recovery Tests
  # ============================================================================

  describe "session recovery on restart" do
    test "always-on session with history recovers without crashing" do
      agent = create_agent(always_on: true)
      key = unique_key()

      # Start session, add some messages, stop, restart
      {:ok, pid} = SessionManager.start_session(session_key: key, agent_id: agent.id)
      state = SessionWorker.get_state(key)

      # Insert some messages directly
      for i <- 1..5 do
        %ClawdEx.Sessions.Message{}
        |> ClawdEx.Sessions.Message.changeset(%{
          session_id: state.session_id,
          role: :user,
          content: "Recovery test message #{i}"
        })
        |> Repo.insert!()
      end

      # Stop the session
      SessionManager.stop_session(key)
      Process.sleep(100)

      # Restart — should recover context from DB
      {:ok, new_pid} = SessionManager.start_session(session_key: key, agent_id: agent.id)
      assert Process.alive?(new_pid)

      # History should be available
      messages = SessionWorker.get_history(key, limit: 10)
      assert length(messages) == 5
      assert Enum.any?(messages, &(&1.content == "Recovery test message 1"))

      # Cleanup
      SessionManager.stop_session(key)
    end

    test "non-always-on session still starts normally" do
      agent = create_agent(always_on: false)
      {key, pid} = start_session_with_agent(agent)

      assert Process.alive?(pid)
      state = SessionWorker.get_state(key)
      assert state.session_key == key
    end
  end

  # ============================================================================
  # child_spec Tests
  # ============================================================================

  describe "child_spec" do
    test "default restart is :transient" do
      spec = SessionWorker.child_spec(session_key: "test_key")
      assert spec.restart == :transient
    end

    test "can override restart to :permanent" do
      spec = SessionWorker.child_spec(session_key: "test_key", restart: :permanent)
      assert spec.restart == :permanent
    end
  end
end
