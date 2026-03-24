defmodule ClawdEx.Tools.A2ABroadcastTest do
  use ClawdEx.DataCase, async: false

  alias ClawdEx.Tools.A2A
  alias ClawdEx.A2A.Router
  alias ClawdEx.Agents.Agent

  setup do
    {:ok, agent1} =
      %Agent{}
      |> Agent.changeset(%{name: "broadcast-agent1-#{System.unique_integer([:positive])}"})
      |> Repo.insert()

    {:ok, agent2} =
      %Agent{}
      |> Agent.changeset(%{name: "broadcast-agent2-#{System.unique_integer([:positive])}"})
      |> Repo.insert()

    {:ok, agent3} =
      %Agent{}
      |> Agent.changeset(%{name: "broadcast-agent3-#{System.unique_integer([:positive])}"})
      |> Repo.insert()

    Router.register(agent1.id, ["coding"])
    Router.register(agent2.id, ["testing"])
    Router.register(agent3.id, ["deployment"])

    on_exit(fn ->
      Router.unregister(agent1.id)
      Router.unregister(agent2.id)
      Router.unregister(agent3.id)
    end)

    %{agent1: agent1, agent2: agent2, agent3: agent3}
  end

  # ============================================================================
  # Action: broadcast
  # ============================================================================

  describe "execute/2 with action: broadcast" do
    test "broadcasts to all other registered agents", %{agent1: agent1, agent2: agent2, agent3: agent3} do
      # Subscribe to receive messages on agent2 and agent3
      Phoenix.PubSub.subscribe(ClawdEx.PubSub, "a2a:#{agent2.id}")
      Phoenix.PubSub.subscribe(ClawdEx.PubSub, "a2a:#{agent3.id}")

      params = %{
        "action" => "broadcast",
        "content" => "System update: deployment starting"
      }

      assert {:ok, result} = A2A.execute(params, context(agent1))
      assert result.sent_count >= 2
      assert result.message =~ "Broadcast sent"

      # Should receive on both agents
      assert_receive {:a2a_message, msg2}, 500
      assert msg2.content == "System update: deployment starting"
      assert msg2.metadata["broadcast"] == true

      assert_receive {:a2a_message, msg3}, 500
      assert msg3.content == "System update: deployment starting"
    end

    test "does not send to self", %{agent1: agent1} do
      # Subscribe to our own channel to verify we don't receive it
      Phoenix.PubSub.subscribe(ClawdEx.PubSub, "a2a:#{agent1.id}")

      params = %{
        "action" => "broadcast",
        "content" => "Should not echo"
      }

      {:ok, _result} = A2A.execute(params, context(agent1))

      refute_receive {:a2a_message, _}, 200
    end

    test "broadcasts with priority", %{agent1: agent1, agent2: agent2} do
      Phoenix.PubSub.subscribe(ClawdEx.PubSub, "a2a:#{agent2.id}")

      params = %{
        "action" => "broadcast",
        "content" => "Urgent broadcast",
        "priority" => 1
      }

      assert {:ok, _result} = A2A.execute(params, context(agent1))

      assert_receive {:a2a_message, msg}, 500
      assert msg.priority == 1
    end

    test "returns error without content", %{agent1: agent1} do
      params = %{"action" => "broadcast"}

      assert {:error, msg} = A2A.execute(params, context(agent1))
      assert msg =~ "content"
    end

    test "includes metadata in broadcast", %{agent1: agent1, agent2: agent2} do
      Phoenix.PubSub.subscribe(ClawdEx.PubSub, "a2a:#{agent2.id}")

      params = %{
        "action" => "broadcast",
        "content" => "Update with meta",
        "metadata" => %{"version" => "2.0"}
      }

      {:ok, _result} = A2A.execute(params, context(agent1))

      assert_receive {:a2a_message, msg}, 500
      assert msg.metadata["version"] == "2.0"
      assert msg.metadata["broadcast"] == true
    end
  end

  # ============================================================================
  # Action: check_delegation
  # ============================================================================

  describe "execute/2 with action: check_delegation" do
    test "returns task status for valid task", %{agent1: agent1, agent2: agent2} do
      # Create a task via delegation first
      params = %{
        "action" => "delegate",
        "targetAgentId" => agent2.id,
        "taskTitle" => "Check this task",
        "taskDescription" => "Test delegation check"
      }

      {:ok, delegate_result} = A2A.execute(params, context(agent1))
      task_id = delegate_result.task_id

      # Now check it
      check_params = %{
        "action" => "check_delegation",
        "taskId" => task_id
      }

      assert {:ok, result} = A2A.execute(check_params, context(agent1))
      assert result.task_id == task_id
      assert result.title == "Check this task"
      assert result.status == "pending"
      assert result.message =~ "pending"
    end

    test "returns error for non-existent task", %{agent1: agent1} do
      params = %{
        "action" => "check_delegation",
        "taskId" => 999_999
      }

      assert {:error, msg} = A2A.execute(params, context(agent1))
      assert msg =~ "not found"
    end

    test "returns error without taskId", %{agent1: agent1} do
      params = %{"action" => "check_delegation"}

      assert {:error, msg} = A2A.execute(params, context(agent1))
      assert msg =~ "taskId"
    end

    test "returns completed task with result", %{agent1: agent1, agent2: agent2} do
      # Create and complete a task
      params = %{
        "action" => "delegate",
        "targetAgentId" => agent2.id,
        "taskTitle" => "Completable task"
      }

      {:ok, delegate_result} = A2A.execute(params, context(agent1))
      task_id = delegate_result.task_id

      # Complete the task
      ClawdEx.Tasks.Manager.complete_task(task_id, %{"output" => "done"})

      # Check status
      check_params = %{
        "action" => "check_delegation",
        "taskId" => task_id
      }

      {:ok, result} = A2A.execute(check_params, context(agent1))
      assert result.status == "completed"
      assert result.result == %{"output" => "done"}
      assert result.completed_at != nil
    end
  end

  # ============================================================================
  # Priority in send/request/delegate
  # ============================================================================

  describe "priority parameter in existing actions" do
    test "send with custom priority persists to DB", %{agent1: agent1, agent2: agent2} do
      params = %{
        "action" => "send",
        "targetAgentId" => agent2.id,
        "content" => "Urgent message",
        "priority" => 1
      }

      assert {:ok, result} = A2A.execute(params, context(agent1))
      assert result.priority == 1

      msg = Repo.get_by(ClawdEx.A2A.Message, message_id: result.message_id)
      assert msg.priority == 1
    end

    test "send defaults to priority 5", %{agent1: agent1, agent2: agent2} do
      params = %{
        "action" => "send",
        "targetAgentId" => agent2.id,
        "content" => "Normal message"
      }

      {:ok, result} = A2A.execute(params, context(agent1))

      msg = Repo.get_by(ClawdEx.A2A.Message, message_id: result.message_id)
      assert msg.priority == 5
    end
  end

  # ============================================================================
  # Updated action enum
  # ============================================================================

  describe "parameters/0" do
    test "includes new actions" do
      params = A2A.parameters()
      actions = params[:properties][:action][:enum]
      assert "broadcast" in actions
      assert "check_delegation" in actions
    end

    test "includes priority parameter" do
      params = A2A.parameters()
      assert Map.has_key?(params[:properties], :priority)
    end

    test "includes taskId parameter" do
      params = A2A.parameters()
      assert Map.has_key?(params[:properties], :taskId)
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
