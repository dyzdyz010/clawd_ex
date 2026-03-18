defmodule ClawdEx.Automation.CronExecutorTest do
  use ExUnit.Case, async: true

  alias ClawdEx.Automation.{CronJob, CronJobRun}

  # CronExecutor.execute/2 requires DB + SessionManager, so we focus on
  # testing struct construction, field defaults, and changeset validations
  # that exercise the same code paths the executor relies on.

  describe "CronJob struct and defaults" do
    test "has expected default values" do
      job = %CronJob{}
      assert job.enabled == true
      assert job.run_count == 0
      assert job.payload_type == "system_event"
      assert job.cleanup == "delete"
      assert job.timeout_seconds == 300
      assert job.timezone == "UTC"
      assert job.notify == []
      assert job.metadata == %{}
    end

    test "system_event payload_type is valid" do
      job = %CronJob{payload_type: "system_event"}
      assert job.payload_type == "system_event"
    end

    test "agent_turn payload_type is valid" do
      job = %CronJob{payload_type: "agent_turn"}
      assert job.payload_type == "agent_turn"
    end

    test "fields can be set" do
      job = %CronJob{
        name: "test-job",
        schedule: "0 * * * *",
        command: "echo hello",
        payload_type: "system_event",
        agent_id: "42",
        session_key: "cron:test",
        timeout_seconds: 60
      }

      assert job.name == "test-job"
      assert job.schedule == "0 * * * *"
      assert job.command == "echo hello"
      assert job.agent_id == "42"
      assert job.session_key == "cron:test"
      assert job.timeout_seconds == 60
    end
  end

  describe "CronJob.changeset/2" do
    test "valid changeset with required fields" do
      changeset = CronJob.changeset(%CronJob{}, %{
        name: "my-job",
        schedule: "*/5 * * * *",
        command: "check inbox"
      })

      assert changeset.valid?
    end

    test "invalid changeset missing required fields" do
      changeset = CronJob.changeset(%CronJob{}, %{})
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset, :name)
      assert "can't be blank" in errors_on(changeset, :schedule)
      assert "can't be blank" in errors_on(changeset, :command)
    end

    test "invalid payload_type is rejected" do
      changeset = CronJob.changeset(%CronJob{}, %{
        name: "bad",
        schedule: "* * * * *",
        command: "echo",
        payload_type: "invalid_type"
      })

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset, :payload_type)
    end

    test "invalid cleanup is rejected" do
      changeset = CronJob.changeset(%CronJob{}, %{
        name: "bad",
        schedule: "* * * * *",
        command: "echo",
        cleanup: "nope"
      })

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset, :cleanup)
    end

    test "text field is aliased to command" do
      changeset = CronJob.changeset(%CronJob{}, %{
        name: "alias-test",
        schedule: "* * * * *",
        text: "hello from text"
      })

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :command) == "hello from text"
    end
  end

  describe "CronJobRun struct" do
    test "has expected fields" do
      now = DateTime.utc_now()

      run = %CronJobRun{
        status: "running",
        started_at: now
      }

      assert run.status == "running"
      assert run.started_at == now
      assert run.exit_code == nil
      assert run.output == nil
      assert run.error == nil
    end

    test "can represent completed run" do
      run = %CronJobRun{
        status: "completed",
        exit_code: 0,
        output: "success"
      }

      assert run.status == "completed"
      assert run.exit_code == 0
      assert run.output == "success"
    end

    test "can represent failed run" do
      run = %CronJobRun{
        status: "failed",
        exit_code: 1,
        error: "something went wrong"
      }

      assert run.status == "failed"
      assert run.exit_code == 1
      assert run.error == "something went wrong"
    end
  end

  describe "CronJobRun.changeset/2" do
    test "valid changeset" do
      changeset = CronJobRun.changeset(%CronJobRun{}, %{
        job_id: Ecto.UUID.generate(),
        started_at: DateTime.utc_now(),
        status: "running"
      })

      assert changeset.valid?
    end

    test "invalid status is rejected" do
      changeset = CronJobRun.changeset(%CronJobRun{}, %{
        job_id: Ecto.UUID.generate(),
        started_at: DateTime.utc_now(),
        status: "banana"
      })

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset, :status)
    end

    test "missing required fields is invalid" do
      changeset = CronJobRun.changeset(%CronJobRun{}, %{})
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset, :job_id)
      assert "can't be blank" in errors_on(changeset, :started_at)
      assert "can't be blank" in errors_on(changeset, :status)
    end
  end

  # Helper to extract error messages from a changeset
  defp errors_on(changeset, field) do
    changeset.errors
    |> Keyword.get_values(field)
    |> Enum.map(fn {msg, _opts} -> msg end)
  end
end
