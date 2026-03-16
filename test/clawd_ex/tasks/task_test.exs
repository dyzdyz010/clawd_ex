defmodule ClawdEx.Tasks.TaskTest do
  use ClawdEx.DataCase, async: true

  alias ClawdEx.Tasks.Task

  describe "changeset/2" do
    test "valid changeset with required fields" do
      changeset = Task.changeset(%Task{}, %{title: "Test Task"})
      assert changeset.valid?
    end

    test "invalid without title" do
      changeset = Task.changeset(%Task{}, %{})
      refute changeset.valid?
      assert %{title: ["can't be blank"]} = errors_on(changeset)
    end

    test "valid with all fields" do
      attrs = %{
        title: "Full Task",
        description: "A detailed description",
        status: "running",
        priority: 3,
        session_key: "agent:1:abc",
        context: %{"key" => "value"},
        result: %{"output" => "data"},
        max_retries: 5,
        retry_count: 1,
        timeout_seconds: 300,
        scheduled_at: DateTime.utc_now(),
        started_at: DateTime.utc_now(),
        completed_at: DateTime.utc_now(),
        last_heartbeat_at: DateTime.utc_now()
      }

      changeset = Task.changeset(%Task{}, attrs)
      assert changeset.valid?
    end
  end

  describe "status validation" do
    test "accepts all valid statuses" do
      for status <- ~w(pending assigned running paused completed failed cancelled) do
        changeset = Task.changeset(%Task{}, %{title: "Task", status: status})
        assert changeset.valid?, "Expected status #{status} to be valid"
      end
    end

    test "rejects invalid status" do
      changeset = Task.changeset(%Task{}, %{title: "Task", status: "invalid_status"})
      refute changeset.valid?
      assert %{status: [_msg]} = errors_on(changeset)
    end
  end

  describe "priority validation" do
    test "accepts priority in range 1-10" do
      for priority <- [1, 5, 10] do
        changeset = Task.changeset(%Task{}, %{title: "Task", priority: priority})
        assert changeset.valid?, "Expected priority #{priority} to be valid"
      end
    end

    test "rejects priority below 1" do
      changeset = Task.changeset(%Task{}, %{title: "Task", priority: 0})
      refute changeset.valid?
      assert %{priority: [_msg]} = errors_on(changeset)
    end

    test "rejects priority above 10" do
      changeset = Task.changeset(%Task{}, %{title: "Task", priority: 11})
      refute changeset.valid?
      assert %{priority: [_msg]} = errors_on(changeset)
    end
  end

  describe "defaults" do
    test "status defaults to pending" do
      changeset = Task.changeset(%Task{}, %{title: "Task"})
      # Default is set on the schema, not the changeset
      task = %Task{}
      assert task.status == "pending"
    end

    test "priority defaults to 5" do
      task = %Task{}
      assert task.priority == 5
    end

    test "max_retries defaults to 3" do
      task = %Task{}
      assert task.max_retries == 3
    end

    test "retry_count defaults to 0" do
      task = %Task{}
      assert task.retry_count == 0
    end

    test "timeout_seconds defaults to 600" do
      task = %Task{}
      assert task.timeout_seconds == 600
    end

    test "context defaults to empty map" do
      task = %Task{}
      assert task.context == %{}
    end

    test "result defaults to empty map" do
      task = %Task{}
      assert task.result == %{}
    end
  end

  describe "statuses/0" do
    test "returns all valid status values" do
      statuses = Task.statuses()
      assert "pending" in statuses
      assert "assigned" in statuses
      assert "running" in statuses
      assert "paused" in statuses
      assert "completed" in statuses
      assert "failed" in statuses
      assert "cancelled" in statuses
      assert length(statuses) == 7
    end
  end
end
