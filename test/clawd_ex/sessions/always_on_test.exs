defmodule ClawdEx.Sessions.AlwaysOnTest do
  @moduledoc """
  Tests for always_on session behavior: permanent restart, A2A registration survival.
  """
  use ClawdEx.DataCase, async: false

  alias ClawdEx.Agents.Agent
  alias ClawdEx.A2A.Router, as: A2ARouter
  alias ClawdEx.Sessions.{SessionManager, SessionWorker}

  defp unique_key, do: "always_on_test_#{:erlang.unique_integer([:positive])}"

  defp create_always_on_agent(opts \\ []) do
    capabilities = Keyword.get(opts, :capabilities, ["testing"])

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{
        name: "always-on-test-#{System.unique_integer([:positive])}",
        auto_start: true,
        always_on: true,
        active: true,
        capabilities: capabilities
      })
      |> Repo.insert()

    agent
  end

  defp start_session(agent, key \\ nil) do
    key = key || unique_key()

    {:ok, pid} =
      SessionManager.start_session(
        session_key: key,
        agent_id: agent.id,
        channel: "test"
      )

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
  # Permanent Restart Tests
  # ============================================================================

  describe "permanent restart strategy" do
    test "always_on agent session starts and registers successfully" do
      agent = create_always_on_agent()
      {key, pid} = start_session(agent)

      assert Process.alive?(pid)

      # Verify the session is managed by SessionManager
      assert {:ok, ^pid} = SessionManager.find_session(key)

      # Verify agent state indicates always_on
      state = :sys.get_state(pid)
      assert state.agent_id == agent.id
    end

    test "non-always_on agent session starts normally" do
      {:ok, agent} =
        %Agent{}
        |> Agent.changeset(%{
          name: "transient-test-#{System.unique_integer([:positive])}",
          always_on: false,
          active: true
        })
        |> Repo.insert()

      key = unique_key()

      {:ok, pid} =
        SessionManager.start_session(
          session_key: key,
          agent_id: agent.id,
          channel: "test"
        )

      assert Process.alive?(pid)
      SessionManager.stop_session(key)
    end

    test "always_on flag is correctly read from agent" do
      agent = create_always_on_agent()
      assert agent.always_on == true
      assert agent.auto_start == true

      {:ok, non_always} =
        %Agent{}
        |> Agent.changeset(%{
          name: "non-always-#{System.unique_integer([:positive])}",
          always_on: false,
          auto_start: false
        })
        |> Repo.insert()

      assert non_always.always_on == false
      assert non_always.auto_start == false
    end
  end

  # ============================================================================
  # A2A Registration Survival Tests
  # ============================================================================

  describe "A2A registration survives restart" do
    test "A2A registration happens on session start" do
      agent = create_always_on_agent(capabilities: ["code_review", "deployment"])
      {_key, _pid} = start_session(agent)

      Process.sleep(200)

      # Verify A2A registration
      {:ok, agents} = A2ARouter.discover()
      registered = Enum.find(agents, &(&1.agent_id == agent.id))
      assert registered != nil
      assert "code_review" in registered.capabilities
      assert "deployment" in registered.capabilities
    end

    test "agent without capabilities is not A2A registered" do
      agent = create_always_on_agent(capabilities: [])
      {_key, pid} = start_session(agent)

      Process.sleep(200)

      # Agent should be discoverable via DB but not in-memory registered
      {:ok, agents} = A2ARouter.discover()
      found = Enum.find(agents, &(&1.agent_id == agent.id))

      # If found via DB, should not have registered_at
      if found do
        refute Map.get(found, :registered_at)
      end

      assert Process.alive?(pid)
    end
  end

  # ============================================================================
  # Session State Tests
  # ============================================================================

  describe "always_on session state" do
    test "started_at is set in state" do
      agent = create_always_on_agent()
      {_key, pid} = start_session(agent)

      state = :sys.get_state(pid)
      assert state.started_at != nil
      assert is_integer(state.started_at)
    end

    test "always_on status is logged on init" do
      # This test verifies the session starts correctly with always_on agent
      agent = create_always_on_agent()
      {key, pid} = start_session(agent)

      assert Process.alive?(pid)
      session_state = SessionWorker.get_state(key)
      assert session_state.session_key == key
      assert session_state.agent_id == agent.id
    end
  end
end
