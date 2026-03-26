defmodule ClawdEx.Tools.TaskToolTest do
  use ClawdEx.DataCase, async: false

  alias ClawdEx.Tools.TaskTool
  alias ClawdEx.Agents.Agent
  alias ClawdEx.Tasks.Task

  setup do
    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{name: "tasktool-agent-#{System.unique_integer([:positive])}"})
      |> Repo.insert()

    %{agent: agent}
  end

  # ============================================================================
  # Action: create
  # ============================================================================

  describe "execute/2 with action: create" do
    test "creates a task with title", %{agent: agent} do
      params = %{"action" => "create", "title" => "New Task"}

      assert {:ok, result} = TaskTool.execute(params, context(agent))
      assert result.task_id
      assert result.title == "New Task"
      assert result.status == "pending"
      assert result.priority == 5
      assert result.message =~ "created"
    end

    test "creates a task with all optional fields", %{agent: agent} do
      params = %{
        "action" => "create",
        "title" => "Detailed Task",
        "description" => "A task with details",
        "priority" => 2,
        "context" => %{"source" => "test"}
      }

      assert {:ok, result} = TaskTool.execute(params, context(agent))
      assert result.title == "Detailed Task"
      assert result.priority == 2
    end

    test "creates subtask with parentTaskId", %{agent: agent} do
      # Create parent task first
      {:ok, parent} = TaskTool.execute(%{"action" => "create", "title" => "Parent"}, context(agent))

      params = %{
        "action" => "create",
        "title" => "Subtask",
        "parentTaskId" => parent.task_id
      }

      assert {:ok, result} = TaskTool.execute(params, context(agent))
      assert result.task_id

      # Verify parent-child relationship
      child = Repo.get(Task, result.task_id)
      assert child.parent_task_id == parent.task_id
    end

    test "uses default title when none provided", %{agent: agent} do
      assert {:ok, result} = TaskTool.execute(%{"action" => "create"}, context(agent))
      assert result.title == "Untitled Task"
    end
  end

  # ============================================================================
  # Action: list
  # ============================================================================

  describe "execute/2 with action: list" do
    test "lists tasks for the agent", %{agent: agent} do
      ctx = context(agent)
      TaskTool.execute(%{"action" => "create", "title" => "Task A"}, ctx)
      TaskTool.execute(%{"action" => "create", "title" => "Task B"}, ctx)

      assert {:ok, result} = TaskTool.execute(%{"action" => "list"}, ctx)
      assert result.count >= 2
      assert is_list(result.tasks)

      titles = Enum.map(result.tasks, & &1.title)
      assert "Task A" in titles
      assert "Task B" in titles
    end

    test "filters by status", %{agent: agent} do
      ctx = context(agent)
      {:ok, t1} = TaskTool.execute(%{"action" => "create", "title" => "To Complete"}, ctx)

      TaskTool.execute(
        %{"action" => "update", "taskId" => t1.task_id, "status" => "completed"},
        ctx
      )

      TaskTool.execute(%{"action" => "create", "title" => "Still Pending"}, ctx)

      assert {:ok, result} =
               TaskTool.execute(%{"action" => "list", "filterStatus" => "pending"}, ctx)

      statuses = Enum.map(result.tasks, & &1.status)
      assert Enum.all?(statuses, &(&1 == "pending"))
    end

    test "respects limit", %{agent: agent} do
      ctx = context(agent)

      for i <- 1..5 do
        TaskTool.execute(%{"action" => "create", "title" => "Task #{i}"}, ctx)
      end

      assert {:ok, result} = TaskTool.execute(%{"action" => "list", "limit" => 2}, ctx)
      assert result.count == 2
    end

    test "returns task fields in list", %{agent: agent} do
      ctx = context(agent)
      TaskTool.execute(%{"action" => "create", "title" => "Detailed"}, ctx)

      {:ok, result} = TaskTool.execute(%{"action" => "list"}, ctx)
      task = hd(result.tasks)

      assert Map.has_key?(task, :id)
      assert Map.has_key?(task, :title)
      assert Map.has_key?(task, :status)
      assert Map.has_key?(task, :priority)
      assert Map.has_key?(task, :agent_id)
      assert Map.has_key?(task, :inserted_at)
    end
  end

  # ============================================================================
  # Action: update
  # ============================================================================

  describe "execute/2 with action: update" do
    test "updates task status", %{agent: agent} do
      ctx = context(agent)
      {:ok, created} = TaskTool.execute(%{"action" => "create", "title" => "To Update"}, ctx)

      assert {:ok, result} =
               TaskTool.execute(
                 %{"action" => "update", "taskId" => created.task_id, "status" => "running"},
                 ctx
               )

      assert result.status == "running"
      assert result.message =~ "updated"
    end

    test "updates task with result data", %{agent: agent} do
      ctx = context(agent)
      {:ok, created} = TaskTool.execute(%{"action" => "create", "title" => "With Result"}, ctx)

      result_data = %{"output" => "done", "items_processed" => 42}

      assert {:ok, result} =
               TaskTool.execute(
                 %{
                   "action" => "update",
                   "taskId" => created.task_id,
                   "status" => "completed",
                   "result" => result_data
                 },
                 ctx
               )

      assert result.status == "completed"
    end

    test "returns error without taskId or for non-existent task", %{agent: agent} do
      assert {:error, msg} = TaskTool.execute(%{"action" => "update", "status" => "running"}, context(agent))
      assert msg =~ "taskId"

      assert {:error, msg2} = TaskTool.execute(%{"action" => "update", "taskId" => -1, "status" => "running"}, context(agent))
      assert msg2 =~ "not found"
    end
  end

  # ============================================================================
  # Action: heartbeat
  # ============================================================================

  describe "execute/2 with action: heartbeat" do
    test "records heartbeat for task", %{agent: agent} do
      ctx = context(agent)
      {:ok, created} = TaskTool.execute(%{"action" => "create", "title" => "Heartbeat"}, ctx)

      assert {:ok, result} =
               TaskTool.execute(%{"action" => "heartbeat", "taskId" => created.task_id}, ctx)

      assert result.task_id == created.task_id
      assert result.last_heartbeat_at != nil
      assert result.message =~ "Heartbeat"
    end

    test "returns error without taskId or for non-existent task", %{agent: agent} do
      assert {:error, msg} = TaskTool.execute(%{"action" => "heartbeat"}, context(agent))
      assert msg =~ "taskId"

      assert {:error, msg2} = TaskTool.execute(%{"action" => "heartbeat", "taskId" => -1}, context(agent))
      assert msg2 =~ "not found"
    end
  end

  # ============================================================================
  # Action: delegate
  # ============================================================================

  describe "execute/2 with action: delegate" do
    test "delegates task to another agent", %{agent: agent} do
      {:ok, target} =
        %Agent{}
        |> Agent.changeset(%{name: "delegate-target-#{System.unique_integer([:positive])}"})
        |> Repo.insert()

      ctx = context(agent)
      {:ok, created} = TaskTool.execute(%{"action" => "create", "title" => "To Delegate"}, ctx)

      assert {:ok, result} =
               TaskTool.execute(
                 %{
                   "action" => "delegate",
                   "taskId" => created.task_id,
                   "targetAgentId" => target.id
                 },
                 ctx
               )

      assert result.agent_id == target.id
      assert result.status == "pending"
      assert result.message =~ "delegated"
    end

    test "returns error for missing params or non-existent task", %{agent: agent} do
      ctx = context(agent)

      # Missing taskId
      assert {:error, msg} = TaskTool.execute(%{"action" => "delegate", "targetAgentId" => 999}, ctx)
      assert msg =~ "taskId"

      # Missing targetAgentId
      {:ok, created} = TaskTool.execute(%{"action" => "create", "title" => "Task"}, ctx)
      assert {:error, msg2} = TaskTool.execute(%{"action" => "delegate", "taskId" => created.task_id}, ctx)
      assert msg2 =~ "targetAgentId"

      # Non-existent task
      assert {:error, msg3} = TaskTool.execute(%{"action" => "delegate", "taskId" => -1, "targetAgentId" => 999}, ctx)
      assert msg3 =~ "not found"
    end
  end

  # ============================================================================
  # Unknown action
  # ============================================================================

  describe "execute/2 with unknown action" do
    test "returns error for unknown action", %{agent: agent} do
      assert {:error, msg} =
               TaskTool.execute(%{"action" => "unknown"}, context(agent))

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
