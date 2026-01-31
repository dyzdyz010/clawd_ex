defmodule ClawdEx.Tools.CronTest do
  use ClawdEx.DataCase, async: false

  alias ClawdEx.Tools.Cron
  alias ClawdEx.Automation.CronJob
  alias ClawdEx.Repo

  @agent_id "test-agent"

  setup do
    # Clean up any existing jobs
    Repo.delete_all(CronJob)
    :ok
  end

  describe "execute/2 with action: status" do
    test "returns status with no jobs" do
      {:ok, result} = Cron.execute(%{"action" => "status"}, context())

      assert result.total_jobs == 0
      assert result.enabled_jobs == 0
      assert result.next_run == nil
    end

    test "returns status with jobs" do
      create_job!("Test Job 1", true)
      create_job!("Test Job 2", false)

      {:ok, result} = Cron.execute(%{"action" => "status"}, context())

      assert result.total_jobs == 2
      assert result.enabled_jobs == 1
      assert result.next_run != nil
      assert result.next_run.name == "Test Job 1"
    end
  end

  describe "execute/2 with action: list" do
    test "lists only enabled jobs by default" do
      create_job!("Enabled Job", true)
      create_job!("Disabled Job", false)

      {:ok, result} = Cron.execute(%{"action" => "list"}, context())

      assert length(result.jobs) == 1
      assert hd(result.jobs).name == "Enabled Job"
    end

    test "lists all jobs when includeDisabled is true" do
      create_job!("Enabled Job", true)
      create_job!("Disabled Job", false)

      {:ok, result} = Cron.execute(%{"action" => "list", "includeDisabled" => true}, context())

      assert length(result.jobs) == 2
    end
  end

  describe "execute/2 with action: add" do
    test "creates a new cron job" do
      params = %{
        "action" => "add",
        "job" => %{
          "name" => "My Test Job",
          "schedule" => "*/5 * * * *",
          "text" => "Do something every 5 minutes",
          "enabled" => true
        }
      }

      {:ok, result} = Cron.execute(params, context())

      assert result.job.name == "My Test Job"
      assert result.job.schedule == "*/5 * * * *"
      # text is stored as command in DB
      assert result.job.enabled == true
    end

    test "creates job with minimal required fields" do
      params = %{"action" => "add", "job" => %{
        "name" => "Minimal Job",
        "text" => "Do something"
      }}

      {:ok, result} = Cron.execute(params, context())

      assert result.job.name == "Minimal Job"
      assert result.job.schedule == "0 * * * *"
      assert result.job.enabled == true
    end
  end

  describe "execute/2 with action: update" do
    test "updates an existing job" do
      job = create_job!("Original Name", true)

      params = %{
        "action" => "update",
        "jobId" => job.id,
        "patch" => %{"name" => "Updated Name", "enabled" => false}
      }

      {:ok, result} = Cron.execute(params, context())

      assert result.job.name == "Updated Name"
      assert result.job.enabled == false
    end

    test "returns error for non-existent job" do
      params = %{
        "action" => "update",
        "jobId" => Ecto.UUID.generate(),
        "patch" => %{"name" => "New Name"}
      }

      {:error, "Job not found"} = Cron.execute(params, context())
    end
  end

  describe "execute/2 with action: remove" do
    test "removes an existing job" do
      job = create_job!("To Be Deleted", true)

      params = %{"action" => "remove", "jobId" => job.id}

      {:ok, result} = Cron.execute(params, context())

      assert result.deleted == true
      assert result.id == job.id

      # Verify it's actually deleted
      assert Repo.get(CronJob, job.id) == nil
    end

    test "returns error for non-existent job" do
      params = %{"action" => "remove", "jobId" => Ecto.UUID.generate()}

      {:error, "Job not found"} = Cron.execute(params, context())
    end
  end

  describe "execute/2 with action: run" do
    test "triggers job execution" do
      job = create_job!("Runnable Job", true)

      params = %{"action" => "run", "jobId" => job.id}

      {:ok, result} = Cron.execute(params, context())

      assert result.triggered == true
      assert result.job.name == "Runnable Job"
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp context do
    %{agent: %{id: @agent_id}}
  end

  defp create_job!(name, enabled) do
    %CronJob{}
    |> CronJob.changeset(%{
      agent_id: @agent_id,
      name: name,
      schedule: "0 * * * *",
      text: "Test task",
      enabled: enabled
    })
    |> Repo.insert!()
  end
end
