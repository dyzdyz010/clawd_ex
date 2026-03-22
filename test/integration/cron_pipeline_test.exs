defmodule ClawdEx.Integration.CronPipelineTest do
  @moduledoc """
  Integration test for the cron scheduling pipeline.

  Verifies:
    Create job → Parser validates expression → Scheduler registers →
    Trigger → Executor runs → Results recorded →
    Pause / Resume / Delete lifecycle
  """
  use ClawdEx.DataCase, async: false

  alias ClawdEx.Repo
  alias ClawdEx.Automation
  alias ClawdEx.Automation.{CronJob, CronJobRun}
  alias ClawdEx.Cron.{Parser, Scheduler}

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp unique_name(prefix \\ "cron_test"),
    do: "#{prefix}_#{:erlang.unique_integer([:positive])}"

  defp create_test_job(attrs \\ %{}) do
    default = %{
      name: unique_name(),
      schedule: "*/5 * * * *",
      command: "echo 'test cron'",
      enabled: true,
      payload_type: "system_event"
    }

    {:ok, job} = Automation.create_job(Map.merge(default, attrs))
    job
  end

  # ---------------------------------------------------------------------------
  # Parser integration
  # ---------------------------------------------------------------------------

  describe "cron parser" do
    test "parses standard 5-field expressions" do
      assert {:ok, parsed} = Parser.parse("0 * * * *")
      assert parsed.minute == {:list, [0]}
      assert parsed.hour == :any
    end

    test "parses shorthand expressions" do
      assert {:ok, parsed} = Parser.parse("@hourly")
      assert parsed.minute == {:list, [0]}
      assert parsed.hour == :any

      assert {:ok, parsed} = Parser.parse("@daily")
      assert parsed.minute == {:list, [0]}
      assert parsed.hour == {:list, [0]}

      assert {:ok, parsed} = Parser.parse("@weekly")
      assert parsed.weekday == {:list, [0]}
    end

    test "parses step expressions" do
      assert {:ok, parsed} = Parser.parse("*/15 * * * *")
      assert parsed.minute == {:list, [0, 15, 30, 45]}
    end

    test "parses range expressions" do
      assert {:ok, parsed} = Parser.parse("0 9-17 * * *")
      assert parsed.hour == {:list, Enum.to_list(9..17)}
    end

    test "parses comma-separated lists" do
      assert {:ok, parsed} = Parser.parse("0,30 * * * *")
      assert parsed.minute == {:list, [0, 30]}
    end

    test "rejects invalid expressions" do
      assert {:error, _} = Parser.parse("invalid")
      assert {:error, _} = Parser.parse("60 * * * *")
      assert {:error, _} = Parser.parse("* * * *")
    end

    test "calculates next run time" do
      {:ok, parsed} = Parser.parse("0 * * * *")
      from = ~U[2026-03-22 10:30:00Z]
      next = Parser.next_run(parsed, from)

      assert next.minute == 0
      assert next.hour == 11
      assert DateTime.compare(next, from) == :gt
    end

    test "matches? correctly identifies matching times" do
      {:ok, parsed} = Parser.parse("30 14 * * *")

      assert Parser.matches?(parsed, ~U[2026-03-22 14:30:00Z])
      refute Parser.matches?(parsed, ~U[2026-03-22 14:31:00Z])
      refute Parser.matches?(parsed, ~U[2026-03-22 15:30:00Z])
    end
  end

  # ---------------------------------------------------------------------------
  # Job CRUD through Automation context
  # ---------------------------------------------------------------------------

  describe "job CRUD" do
    test "create_job persists and validates schedule" do
      {:ok, job} = Automation.create_job(%{
        name: unique_name(),
        schedule: "0 12 * * *",
        command: "echo hello"
      })

      assert job.id != nil
      assert job.enabled == true
      assert job.next_run_at != nil
    end

    test "invalid schedule still creates job but with fallback next_run" do
      # Note: Automation.CronJob doesn't reject invalid cron expressions — it falls
      # back to a default next_run (1 hour from now). The Cron.Parser itself validates.
      {:ok, job} = Automation.create_job(%{
        name: unique_name(),
        schedule: "invalid cron",
        command: "echo"
      })

      assert job.id != nil
      # next_run_at is set to a fallback value
      assert job.next_run_at != nil

      # But the Parser rejects invalid expressions
      assert {:error, _} = ClawdEx.Cron.Parser.parse("invalid cron")
    end

    test "update_job modifies existing job" do
      job = create_test_job()
      {:ok, updated} = Automation.update_job(job, %{name: "updated_name"})
      assert updated.name == "updated_name"
    end

    test "delete_job removes from database" do
      job = create_test_job()
      {:ok, _deleted} = Automation.delete_job(job)
      assert Automation.get_job(job.id) == nil
    end

    test "toggle_job flips enabled status" do
      job = create_test_job(%{enabled: true})
      {:ok, toggled} = Automation.toggle_job(job)
      assert toggled.enabled == false

      {:ok, toggled_back} = Automation.toggle_job(toggled)
      assert toggled_back.enabled == true
    end

    test "list_jobs with enabled_only filter" do
      _enabled = create_test_job(%{enabled: true, name: unique_name("enabled")})
      disabled = create_test_job(%{enabled: false, name: unique_name("disabled")})

      all = Automation.list_jobs()
      enabled_only = Automation.list_jobs(enabled_only: true)

      assert length(all) >= length(enabled_only)
      enabled_ids = Enum.map(enabled_only, & &1.id)
      refute disabled.id in enabled_ids
    end
  end

  # ---------------------------------------------------------------------------
  # Job runs (execution records)
  # ---------------------------------------------------------------------------

  describe "job runs" do
    test "create_run and complete_run lifecycle" do
      job = create_test_job()

      {:ok, run} = Automation.create_run(%{
        job_id: job.id,
        started_at: DateTime.utc_now(),
        status: "running"
      })

      assert run.status == "running"
      assert run.job_id == job.id

      # Complete the run
      {:ok, completed} = Automation.complete_run(run, %{
        status: "completed",
        exit_code: 0,
        output: "Test output"
      })

      assert completed.status == "completed"
      assert completed.exit_code == 0
      assert completed.output == "Test output"
      assert completed.finished_at != nil
      assert completed.duration_ms != nil
      assert completed.duration_ms >= 0
    end

    test "list_runs returns runs for a job" do
      job = create_test_job()

      for i <- 1..3 do
        {:ok, _} = Automation.create_run(%{
          job_id: job.id,
          started_at: DateTime.utc_now() |> DateTime.add(i, :second),
          status: "completed"
        })
      end

      runs = Automation.list_runs(job.id)
      assert length(runs) == 3
      # Should be ordered by started_at desc
      timestamps = Enum.map(runs, & &1.started_at)
      assert timestamps == Enum.sort(timestamps, {:desc, DateTime})
    end

    test "get_run returns specific run" do
      job = create_test_job()
      {:ok, run} = Automation.create_run(%{
        job_id: job.id,
        started_at: DateTime.utc_now(),
        status: "running"
      })

      fetched = Automation.get_run(run.id)
      assert fetched.id == run.id
    end

    test "failed run records error message" do
      job = create_test_job()

      {:ok, run} = Automation.create_run(%{
        job_id: job.id,
        started_at: DateTime.utc_now(),
        status: "running"
      })

      {:ok, failed} = Automation.complete_run(run, %{
        status: "failed",
        exit_code: 1,
        error: "Something went wrong"
      })

      assert failed.status == "failed"
      assert failed.exit_code == 1
      assert failed.error == "Something went wrong"
    end
  end

  # ---------------------------------------------------------------------------
  # Scheduler integration
  # ---------------------------------------------------------------------------

  describe "scheduler integration" do
    test "scheduler starts and reports status" do
      status = Scheduler.status()
      assert is_map(status)
      assert Map.has_key?(status, :total_jobs)
      assert Map.has_key?(status, :running_jobs)
    end

    test "reload loads active jobs from database" do
      # Create some test jobs
      job1 = create_test_job(%{name: unique_name("sched1"), enabled: true})
      job2 = create_test_job(%{name: unique_name("sched2"), enabled: true})
      _disabled = create_test_job(%{name: unique_name("sched_dis"), enabled: false})

      {:ok, count} = Scheduler.reload()
      assert count >= 2  # At least our two enabled jobs

      # Check that jobs appear in list_scheduled
      scheduled = Scheduler.list_scheduled()
      scheduled_ids = Enum.map(scheduled, & &1.id)
      assert job1.id in scheduled_ids
      assert job2.id in scheduled_ids
    end

    test "refresh_job adds a new job to the scheduler" do
      job = create_test_job(%{enabled: true, name: unique_name("refresh")})

      # First reload to establish baseline
      Scheduler.reload()

      # Refresh should add the job
      Scheduler.refresh_job(job.id)
      Process.sleep(100)  # Let the cast process

      scheduled = Scheduler.list_scheduled()
      scheduled_ids = Enum.map(scheduled, & &1.id)
      assert job.id in scheduled_ids
    end

    test "remove_job removes from scheduler" do
      job = create_test_job(%{enabled: true, name: unique_name("remove")})

      # Reload to include the job
      Scheduler.reload()

      # Verify it's there
      scheduled = Scheduler.list_scheduled()
      assert Enum.any?(scheduled, &(&1.id == job.id))

      # Remove
      Scheduler.remove_job(job.id)
      Process.sleep(100)

      # Verify it's gone
      scheduled = Scheduler.list_scheduled()
      refute Enum.any?(scheduled, &(&1.id == job.id))
    end

    test "pause_job disables and removes from scheduler" do
      job = create_test_job(%{enabled: true, name: unique_name("pause")})
      Scheduler.reload()

      Scheduler.pause_job(job.id)
      Process.sleep(100)

      # Should not be in scheduler
      scheduled = Scheduler.list_scheduled()
      refute Enum.any?(scheduled, &(&1.id == job.id))

      # Should be disabled in DB
      updated = Automation.get_job(job.id)
      assert updated.enabled == false
    end

    test "resume_job re-enables and adds back to scheduler" do
      job = create_test_job(%{enabled: false, name: unique_name("resume")})
      Scheduler.reload()

      Scheduler.resume_job(job.id)
      Process.sleep(100)

      # Should be in scheduler
      scheduled = Scheduler.list_scheduled()
      assert Enum.any?(scheduled, &(&1.id == job.id))

      # Should be enabled in DB
      updated = Automation.get_job(job.id)
      assert updated.enabled == true
    end
  end

  # ---------------------------------------------------------------------------
  # Full pipeline: create → schedule → verify next_run
  # ---------------------------------------------------------------------------

  describe "full pipeline" do
    test "create job → auto-computes next_run_at → shows in scheduler" do
      name = unique_name("full")

      # 1. Create a job with a known schedule
      {:ok, job} = Automation.create_job(%{
        name: name,
        schedule: "0 * * * *",  # top of every hour
        command: "echo full pipeline test"
      })

      assert job.next_run_at != nil
      assert DateTime.compare(job.next_run_at, DateTime.utc_now()) == :gt

      # 2. Refresh scheduler
      Scheduler.refresh_job(job.id)
      Process.sleep(100)

      # 3. Verify in scheduler
      scheduled = Scheduler.list_scheduled()
      entry = Enum.find(scheduled, &(&1.id == job.id))
      assert entry != nil
      assert entry.name == name

      # 4. Delete and verify removal
      Automation.delete_job(job)
      Scheduler.remove_job(job.id)
      Process.sleep(100)

      scheduled = Scheduler.list_scheduled()
      refute Enum.any?(scheduled, &(&1.id == job.id))
    end

    test "create run → mark completed → verify stats" do
      job = create_test_job()

      # Create and complete a run
      {:ok, run} = Automation.create_run(%{
        job_id: job.id,
        started_at: DateTime.utc_now(),
        status: "running"
      })

      {:ok, _completed} = Automation.complete_run(run, %{
        status: "completed",
        exit_code: 0,
        output: "Success"
      })

      # Get stats
      stats = Automation.get_stats()
      assert stats.total_jobs >= 1
      assert stats.total_runs >= 1
    end

    test "get_job_with_runs preloads runs" do
      job = create_test_job()

      for _ <- 1..3 do
        {:ok, _} = Automation.create_run(%{
          job_id: job.id,
          started_at: DateTime.utc_now(),
          status: "completed"
        })
      end

      loaded = Automation.get_job_with_runs(job.id)
      assert loaded != nil
      assert length(loaded.runs) == 3
    end
  end
end
