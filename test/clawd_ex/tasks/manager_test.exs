defmodule ClawdEx.Tasks.ManagerTest do
  use ClawdEx.DataCase, async: false

  alias ClawdEx.Tasks.Manager, as: TaskManager
  alias ClawdEx.Tasks.Task
  alias ClawdEx.Agents.Agent

  setup do
    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{name: "task-test-agent-#{System.unique_integer([:positive])}"})
      |> Repo.insert()

    {:ok, agent2} =
      %Agent{}
      |> Agent.changeset(%{name: "task-test-agent2-#{System.unique_integer([:positive])}"})
      |> Repo.insert()

    %{agent: agent, agent2: agent2}
  end

  # ============================================================================
  # CRUD Operations
  # ============================================================================

  describe "create_task/1" do
    test "creates a task with valid attrs" do
      assert {:ok, task} = TaskManager.create_task(%{title: "My Task"})
      assert task.id
      assert task.title == "My Task"
      assert task.status == "pending"
      assert task.priority == 5
    end

    test "creates a task with all fields", %{agent: agent} do
      attrs = %{
        title: "Full Task",
        description: "Detailed desc",
        priority: 2,
        agent_id: agent.id,
        session_key: "agent:#{agent.id}:session1",
        context: %{"source" => "test"},
        max_retries: 5,
        timeout_seconds: 120
      }

      assert {:ok, task} = TaskManager.create_task(attrs)
      assert task.title == "Full Task"
      assert task.description == "Detailed desc"
      assert task.priority == 2
      assert task.agent_id == agent.id
      assert task.context == %{"source" => "test"}
      assert task.max_retries == 5
    end

    test "fails without title" do
      assert {:error, changeset} = TaskManager.create_task(%{description: "No title"})
      assert %{title: ["can't be blank"]} = errors_on(changeset)
    end

    test "fails with invalid priority" do
      assert {:error, changeset} = TaskManager.create_task(%{title: "Task", priority: 0})
      assert %{priority: [_]} = errors_on(changeset)
    end
  end

  describe "get_task/1" do
    test "returns task by id" do
      {:ok, created} = TaskManager.create_task(%{title: "Findable"})
      task = TaskManager.get_task(created.id)
      assert task.id == created.id
      assert task.title == "Findable"
    end

    test "returns nil for non-existent id" do
      assert TaskManager.get_task(-1) == nil
    end
  end

  describe "list_tasks/1" do
    test "returns all tasks ordered by priority and inserted_at" do
      {:ok, _} = TaskManager.create_task(%{title: "Low Priority", priority: 10})
      {:ok, _} = TaskManager.create_task(%{title: "High Priority", priority: 1})
      {:ok, _} = TaskManager.create_task(%{title: "Medium Priority", priority: 5})

      tasks = TaskManager.list_tasks()
      titles = Enum.map(tasks, & &1.title)
      assert List.first(titles) == "High Priority"
      assert List.last(titles) == "Low Priority"
    end

    test "filters by status" do
      {:ok, t1} = TaskManager.create_task(%{title: "Pending Task"})
      {:ok, _} = TaskManager.create_task(%{title: "Running Task"})

      # Start one task to change its status
      TaskManager.assign_task(t1.id, nil, nil)

      pending = TaskManager.list_tasks(status: "pending")
      assert length(pending) >= 1
      assert Enum.all?(pending, &(&1.status == "pending"))
    end

    test "filters by agent_id", %{agent: agent, agent2: agent2} do
      {:ok, _} = TaskManager.create_task(%{title: "Agent1 Task", agent_id: agent.id})
      {:ok, _} = TaskManager.create_task(%{title: "Agent2 Task", agent_id: agent2.id})

      tasks = TaskManager.list_tasks(agent_id: agent.id)
      assert length(tasks) >= 1
      assert Enum.all?(tasks, &(&1.agent_id == agent.id))
    end

    test "filters by parent_task_id" do
      {:ok, parent} = TaskManager.create_task(%{title: "Parent"})
      {:ok, _child} = TaskManager.create_task(%{title: "Child", parent_task_id: parent.id})
      {:ok, _other} = TaskManager.create_task(%{title: "Other"})

      children = TaskManager.list_tasks(parent_task_id: parent.id)
      assert length(children) == 1
      assert hd(children).title == "Child"
    end

    test "respects limit" do
      for i <- 1..5 do
        TaskManager.create_task(%{title: "Task #{i}"})
      end

      tasks = TaskManager.list_tasks(limit: 3)
      assert length(tasks) == 3
    end

    test "filters by list of statuses" do
      {:ok, _} = TaskManager.create_task(%{title: "Pending"})
      {:ok, t2} = TaskManager.create_task(%{title: "To Complete"})
      TaskManager.complete_task(t2.id)

      tasks = TaskManager.list_tasks(status: ["pending", "completed"])
      statuses = Enum.map(tasks, & &1.status)
      assert Enum.all?(statuses, &(&1 in ["pending", "completed"]))
    end
  end

  describe "update_task/2" do
    test "updates task attributes" do
      {:ok, task} = TaskManager.create_task(%{title: "Original"})

      assert {:ok, updated} =
               TaskManager.update_task(task.id, %{title: "Updated", description: "New desc"})

      assert updated.title == "Updated"
      assert updated.description == "New desc"
    end

    test "returns error for non-existent task" do
      assert {:error, :not_found} = TaskManager.update_task(-1, %{title: "X"})
    end
  end

  # ============================================================================
  # Lifecycle Operations
  # ============================================================================

  describe "assign_task/3" do
    test "assigns task to agent", %{agent: agent} do
      {:ok, task} = TaskManager.create_task(%{title: "Assignable"})
      session_key = "agent:#{agent.id}:session1"

      assert {:ok, assigned} = TaskManager.assign_task(task.id, agent.id, session_key)
      assert assigned.status == "assigned"
      assert assigned.agent_id == agent.id
      assert assigned.session_key == session_key
    end

    test "returns error for non-existent task", %{agent: agent} do
      assert {:error, :not_found} = TaskManager.assign_task(-1, agent.id, "key")
    end
  end

  describe "start_task/1" do
    test "moves task to running status and sets timestamps" do
      {:ok, task} = TaskManager.create_task(%{title: "Startable"})

      assert {:ok, started} = TaskManager.start_task(task.id)
      assert started.status == "running"
      assert started.started_at != nil
      assert started.last_heartbeat_at != nil
    end
  end

  describe "complete_task/2" do
    test "marks task as completed with result" do
      {:ok, task} = TaskManager.create_task(%{title: "Completable"})

      result = %{"output" => "success", "items" => 42}
      assert {:ok, completed} = TaskManager.complete_task(task.id, result)
      assert completed.status == "completed"
      assert completed.result == result
      assert completed.completed_at != nil
    end

    test "marks task as completed without result" do
      {:ok, task} = TaskManager.create_task(%{title: "Completable"})

      assert {:ok, completed} = TaskManager.complete_task(task.id)
      assert completed.status == "completed"
    end
  end

  describe "fail_task/2" do
    test "marks task as failed with error info" do
      {:ok, task} = TaskManager.create_task(%{title: "Failable"})

      error = %{"error" => "something went wrong", "code" => 500}
      assert {:ok, failed} = TaskManager.fail_task(task.id, error)
      assert failed.status == "failed"
      assert failed.result == error
      assert failed.completed_at != nil
    end

    test "marks task as failed without error info" do
      {:ok, task} = TaskManager.create_task(%{title: "Failable"})

      assert {:ok, failed} = TaskManager.fail_task(task.id)
      assert failed.status == "failed"
    end
  end

  describe "cancel_task/1" do
    test "cancels a task" do
      {:ok, task} = TaskManager.create_task(%{title: "Cancellable"})

      assert {:ok, cancelled} = TaskManager.cancel_task(task.id)
      assert cancelled.status == "cancelled"
      assert cancelled.completed_at != nil
    end

    test "returns error for non-existent task" do
      assert {:error, :not_found} = TaskManager.cancel_task(-1)
    end
  end

  # ============================================================================
  # Heartbeat
  # ============================================================================

  describe "heartbeat/1" do
    test "updates last_heartbeat_at" do
      {:ok, task} = TaskManager.create_task(%{title: "Heartbeatable"})

      assert {:ok, updated} = TaskManager.heartbeat(task.id)
      assert updated.last_heartbeat_at != nil
    end

    test "successive heartbeats update the timestamp" do
      {:ok, task} = TaskManager.create_task(%{title: "Heartbeatable"})

      {:ok, first} = TaskManager.heartbeat(task.id)
      Process.sleep(10)
      {:ok, second} = TaskManager.heartbeat(task.id)

      assert DateTime.compare(second.last_heartbeat_at, first.last_heartbeat_at) in [:gt, :eq]
    end

    test "returns error for non-existent task" do
      assert {:error, :not_found} = TaskManager.heartbeat(-1)
    end
  end

  # ============================================================================
  # Delegate
  # ============================================================================

  describe "delegate_task/2" do
    test "reassigns task to new agent and resets to pending", %{agent: agent, agent2: agent2} do
      {:ok, task} =
        TaskManager.create_task(%{
          title: "Delegatable",
          agent_id: agent.id,
          session_key: "agent:#{agent.id}:s1"
        })

      assert {:ok, delegated} = TaskManager.delegate_task(task.id, agent2.id)
      assert delegated.agent_id == agent2.id
      assert delegated.status == "pending"
      assert delegated.session_key == nil
    end

    test "returns error for non-existent task", %{agent2: agent2} do
      assert {:error, :not_found} = TaskManager.delegate_task(-1, agent2.id)
    end
  end

  # ============================================================================
  # Full Lifecycle
  # ============================================================================

  describe "full task lifecycle" do
    test "pending -> assigned -> running -> completed", %{agent: agent} do
      {:ok, task} = TaskManager.create_task(%{title: "Lifecycle Task"})
      assert task.status == "pending"

      {:ok, assigned} = TaskManager.assign_task(task.id, agent.id, "agent:#{agent.id}:s1")
      assert assigned.status == "assigned"

      {:ok, started} = TaskManager.start_task(task.id)
      assert started.status == "running"

      {:ok, completed} = TaskManager.complete_task(task.id, %{"done" => true})
      assert completed.status == "completed"
    end
  end
end
