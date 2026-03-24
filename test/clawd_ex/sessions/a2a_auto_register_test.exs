defmodule ClawdEx.Sessions.A2AAutoRegisterTest do
  use ClawdEx.DataCase, async: false

  alias ClawdEx.Agents.Agent
  alias ClawdEx.A2A.Router, as: A2ARouter
  alias ClawdEx.Sessions.SessionManager

  setup do
    on_exit(fn ->
      for key <- SessionManager.list_sessions(),
          String.contains?(key, "a2a-reg-test") do
        SessionManager.stop_session(key)
      end
    end)

    :ok
  end

  describe "A2A auto-registration on session start" do
    test "registers agent with capabilities when session starts" do
      # Create agent with capabilities
      {:ok, agent} =
        %Agent{}
        |> Agent.changeset(%{
          name: "a2a-reg-test-#{System.unique_integer([:positive])}",
          capabilities: ["code_review", "testing"]
        })
        |> Repo.insert()

      session_key = "a2a-reg-test:#{agent.name}"

      # Start a session for this agent
      {:ok, _pid} = SessionManager.start_session(
        session_key: session_key,
        agent_id: agent.id,
        channel: "test"
      )

      # Give it a moment to initialize
      Process.sleep(100)

      # Verify the agent was registered with A2A Router
      {:ok, agents} = A2ARouter.discover()
      registered = Enum.find(agents, &(&1.agent_id == agent.id))
      assert registered != nil
      assert registered.capabilities == ["code_review", "testing"]

      # Clean up
      SessionManager.stop_session(session_key)
    end

    test "does not register agent without capabilities" do
      {:ok, agent} =
        %Agent{}
        |> Agent.changeset(%{
          name: "a2a-reg-test-nocap-#{System.unique_integer([:positive])}",
          capabilities: []
        })
        |> Repo.insert()

      session_key = "a2a-reg-test:#{agent.name}"

      {:ok, _pid} = SessionManager.start_session(
        session_key: session_key,
        agent_id: agent.id,
        channel: "test"
      )

      Process.sleep(100)

      {:ok, agents} = A2ARouter.discover()
      registered = Enum.find(agents, &(&1.agent_id == agent.id))
      assert registered == nil

      SessionManager.stop_session(session_key)
    end

    test "unregisters agent when session stops" do
      {:ok, agent} =
        %Agent{}
        |> Agent.changeset(%{
          name: "a2a-reg-test-unreg-#{System.unique_integer([:positive])}",
          capabilities: ["deployment"]
        })
        |> Repo.insert()

      session_key = "a2a-reg-test:#{agent.name}"

      {:ok, _pid} = SessionManager.start_session(
        session_key: session_key,
        agent_id: agent.id,
        channel: "test"
      )

      Process.sleep(100)

      # Verify registered
      {:ok, agents} = A2ARouter.discover()
      assert Enum.any?(agents, &(&1.agent_id == agent.id))

      # Stop the session
      SessionManager.stop_session(session_key)
      Process.sleep(100)

      # Verify unregistered
      {:ok, agents_after} = A2ARouter.discover()
      refute Enum.any?(agents_after, &(&1.agent_id == agent.id))
    end
  end
end
