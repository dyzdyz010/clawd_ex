defmodule ClawdEx.Tools.A2ATest do
  use ClawdEx.DataCase, async: false

  alias ClawdEx.Tools.A2A
  alias ClawdEx.A2A.Router
  alias ClawdEx.A2A.Message
  alias ClawdEx.Agents.Agent

  setup do
    {:ok, agent1} =
      %Agent{}
      |> Agent.changeset(%{name: "a2a-tool-agent1-#{System.unique_integer([:positive])}"})
      |> Repo.insert()

    {:ok, agent2} =
      %Agent{}
      |> Agent.changeset(%{name: "a2a-tool-agent2-#{System.unique_integer([:positive])}"})
      |> Repo.insert()

    # Register agents in the Router
    Router.register(agent1.id, ["coding", "review"])
    Router.register(agent2.id, ["testing", "deployment"])

    on_exit(fn ->
      Router.unregister(agent1.id)
      Router.unregister(agent2.id)
    end)

    %{agent1: agent1, agent2: agent2}
  end

  # ============================================================================
  # Tool Metadata
  # ============================================================================

  describe "name/0" do
    test "returns correct name" do
      assert A2A.name() == "a2a"
    end
  end

  describe "parameters/0" do
    test "returns valid parameter schema" do
      params = A2A.parameters()
      assert params[:type] == "object"
      assert is_map(params[:properties])
      assert params[:required] == ["action"]
    end

    test "defines all action types" do
      params = A2A.parameters()
      actions = params[:properties][:action][:enum]
      assert "discover" in actions
      assert "send" in actions
      assert "request" in actions
      assert "delegate" in actions
    end
  end

  # ============================================================================
  # Action: discover
  # ============================================================================

  describe "execute/2 with action: discover" do
    test "lists all registered agents", %{agent1: agent1, agent2: agent2} do
      assert {:ok, result} = A2A.execute(%{"action" => "discover"}, context(agent1))

      assert result.count >= 2
      assert is_list(result.agents)

      ids = Enum.map(result.agents, & &1.agent_id)
      assert agent1.id in ids
      assert agent2.id in ids
    end

    test "filters agents by capability", %{agent1: agent1, agent2: agent2} do
      assert {:ok, result} =
               A2A.execute(%{"action" => "discover", "capability" => "coding"}, context(agent1))

      ids = Enum.map(result.agents, & &1.agent_id)
      assert agent1.id in ids
      refute agent2.id in ids
    end

    test "returns empty when no agents match capability", %{agent1: agent1} do
      assert {:ok, result} =
               A2A.execute(
                 %{"action" => "discover", "capability" => "nonexistent"},
                 context(agent1)
               )

      assert result.count == 0
      assert result.agents == []
    end

    test "returns agent capabilities in result", %{agent1: agent1} do
      {:ok, result} = A2A.execute(%{"action" => "discover"}, context(agent1))

      a1 = Enum.find(result.agents, &(&1.agent_id == agent1.id))
      assert a1.capabilities == ["coding", "review"]
      assert Map.has_key?(a1, :registered_at)
    end
  end

  # ============================================================================
  # Action: send
  # ============================================================================

  describe "execute/2 with action: send" do
    test "sends notification to another agent", %{agent1: agent1, agent2: agent2} do
      Phoenix.PubSub.subscribe(ClawdEx.PubSub, "a2a:#{agent2.id}")

      params = %{
        "action" => "send",
        "targetAgentId" => agent2.id,
        "content" => "Hello from tool!"
      }

      assert {:ok, result} = A2A.execute(params, context(agent1))
      assert result.message_id
      assert result.type == "notification"
      assert result.to_agent_id == agent2.id
      assert result.message =~ "sent"

      assert_receive {:a2a_message, msg}, 500
      assert msg.content == "Hello from tool!"
    end

    test "sends with metadata", %{agent1: agent1, agent2: agent2} do
      params = %{
        "action" => "send",
        "targetAgentId" => agent2.id,
        "content" => "With metadata",
        "metadata" => %{"priority" => "high"}
      }

      assert {:ok, result} = A2A.execute(params, context(agent1))
      assert result.message_id

      msg = Repo.get_by(Message, message_id: result.message_id)
      assert msg.metadata == %{"priority" => "high"}
    end

    test "returns error without targetAgentId", %{agent1: agent1} do
      params = %{"action" => "send", "content" => "Hello"}

      assert {:error, msg} = A2A.execute(params, context(agent1))
      assert msg =~ "targetAgentId"
    end

    test "returns error without content", %{agent1: agent1, agent2: agent2} do
      params = %{"action" => "send", "targetAgentId" => agent2.id}

      assert {:error, msg} = A2A.execute(params, context(agent1))
      assert msg =~ "content"
    end

    test "returns error with empty content", %{agent1: agent1, agent2: agent2} do
      params = %{"action" => "send", "targetAgentId" => agent2.id, "content" => ""}

      assert {:error, msg} = A2A.execute(params, context(agent1))
      assert msg =~ "content"
    end
  end

  # ============================================================================
  # Action: request
  # ============================================================================

  describe "execute/2 with action: request" do
    test "returns error without targetAgentId", %{agent1: agent1} do
      params = %{"action" => "request", "content" => "Question"}

      assert {:error, msg} = A2A.execute(params, context(agent1))
      assert msg =~ "targetAgentId"
    end

    test "returns error without content", %{agent1: agent1, agent2: agent2} do
      params = %{"action" => "request", "targetAgentId" => agent2.id}

      assert {:error, msg} = A2A.execute(params, context(agent1))
      assert msg =~ "content"
    end

    test "times out when no response", %{agent1: agent1, agent2: agent2} do
      params = %{
        "action" => "request",
        "targetAgentId" => agent2.id,
        "content" => "Are you there?",
        "timeout" => 200
      }

      assert {:error, msg} = A2A.execute(params, context(agent1))
      assert msg =~ "timed out"
    end

    test "completes request/response cycle", %{agent1: agent1, agent2: agent2} do
      # Subscribe to receive the request on agent2's topic
      Phoenix.PubSub.subscribe(ClawdEx.PubSub, "a2a:#{agent2.id}")

      caller = self()

      # Execute request in a separate process (it blocks)
      spawn(fn ->
        result =
          A2A.execute(
            %{
              "action" => "request",
              "targetAgentId" => agent2.id,
              "content" => "What is 1+1?",
              "timeout" => 5_000
            },
            context(agent1)
          )

        send(caller, {:tool_result, result})
      end)

      # Wait for the request to arrive
      assert_receive {:a2a_message, msg}, 1_000
      assert msg.type == "request"

      # Respond via Router
      Router.respond(msg.message_id, agent2.id, "2")

      # The tool should return the response
      assert_receive {:tool_result, {:ok, result}}, 5_000
      assert result.type == "response"
      assert result.content == "2"
    end
  end

  # ============================================================================
  # Action: delegate
  # ============================================================================

  describe "execute/2 with action: delegate" do
    test "creates task and sends delegation notification", %{agent1: agent1, agent2: agent2} do
      Phoenix.PubSub.subscribe(ClawdEx.PubSub, "a2a:#{agent2.id}")

      params = %{
        "action" => "delegate",
        "targetAgentId" => agent2.id,
        "taskTitle" => "Review PR #42",
        "taskDescription" => "Please review this PR",
        "taskPriority" => 3,
        "taskContext" => %{"pr_url" => "https://example.com/pr/42"}
      }

      assert {:ok, result} = A2A.execute(params, context(agent1))
      assert result.task_id
      assert result.message_type == "delegation"
      assert result.to_agent_id == agent2.id
      assert result.title == "Review PR #42"
      assert result.message =~ "delegated"

      # Verify task was created in DB
      task = Repo.get(ClawdEx.Tasks.Task, result.task_id)
      assert task.title == "Review PR #42"
      assert task.description == "Please review this PR"
      assert task.priority == 3
      assert task.agent_id == agent2.id
      assert task.context["pr_url"] == "https://example.com/pr/42"
      assert task.context["delegated_by"] == agent1.id

      # Verify delegation notification was sent via PubSub
      assert_receive {:a2a_message, msg}, 500
      assert msg.type == "delegation"
      assert msg.metadata["task_id"] == result.task_id
      assert msg.metadata["task_title"] == "Review PR #42"
    end

    test "returns error without targetAgentId", %{agent1: agent1} do
      params = %{"action" => "delegate", "taskTitle" => "Title"}

      assert {:error, msg} = A2A.execute(params, context(agent1))
      assert msg =~ "targetAgentId"
    end

    test "returns error without taskTitle", %{agent1: agent1, agent2: agent2} do
      params = %{"action" => "delegate", "targetAgentId" => agent2.id}

      assert {:error, msg} = A2A.execute(params, context(agent1))
      assert msg =~ "taskTitle"
    end

    test "returns error with empty taskTitle", %{agent1: agent1, agent2: agent2} do
      params = %{
        "action" => "delegate",
        "targetAgentId" => agent2.id,
        "taskTitle" => ""
      }

      assert {:error, msg} = A2A.execute(params, context(agent1))
      assert msg =~ "taskTitle"
    end

    test "uses default priority of 5", %{agent1: agent1, agent2: agent2} do
      params = %{
        "action" => "delegate",
        "targetAgentId" => agent2.id,
        "taskTitle" => "Default Priority Task"
      }

      {:ok, result} = A2A.execute(params, context(agent1))

      task = Repo.get(ClawdEx.Tasks.Task, result.task_id)
      assert task.priority == 5
    end
  end

  # ============================================================================
  # Unknown action
  # ============================================================================

  describe "execute/2 with unknown action" do
    test "returns error for unknown action", %{agent1: agent1} do
      assert {:error, msg} = A2A.execute(%{"action" => "unknown"}, context(agent1))
      assert msg =~ "Unknown action"
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp context(agent) do
    %{
      agent_id: agent.id,
      session_key: "agent:#{agent.id}:test-session"
    }
  end
end
