defmodule ClawdEx.Cron.SchedulerTest do
  use ExUnit.Case, async: true

  alias ClawdEx.Cron.Scheduler

  # These tests focus on the GenServer logic using process messaging.
  # Database-dependent tests are skipped if Repo isn't available.

  describe "start_link/1" do
    test "starts the scheduler process" do
      # Use a unique name to avoid conflicts with the global scheduler
      name = :"test_scheduler_#{System.unique_integer([:positive])}"

      {:ok, pid} = GenServer.start_link(Scheduler, [], name: name)
      assert Process.alive?(pid)

      GenServer.stop(pid)
    end
  end

  describe "scheduler state" do
    test "initial state has empty jobs and running sets" do
      name = :"test_scheduler_#{System.unique_integer([:positive])}"
      {:ok, pid} = GenServer.start_link(Scheduler, [], name: name)

      # The scheduler starts with an empty state before :load_jobs fires
      # We can check the status
      status = GenServer.call(pid, :status)
      assert status.total_jobs == 0
      assert status.running_jobs == 0

      GenServer.stop(pid)
    end
  end

  describe "handle_info/2" do
    test ":tick message is handled without crashing" do
      name = :"test_scheduler_#{System.unique_integer([:positive])}"
      {:ok, pid} = GenServer.start_link(Scheduler, [], name: name)

      # Send tick directly
      send(pid, :tick)

      # Should still be alive
      Process.sleep(50)
      assert Process.alive?(pid)

      GenServer.stop(pid)
    end

    test ":job_completed removes job from running set" do
      name = :"test_scheduler_#{System.unique_integer([:positive])}"
      {:ok, pid} = GenServer.start_link(Scheduler, [], name: name)

      # Simulate a job completion
      job_id = Ecto.UUID.generate()
      send(pid, {:job_completed, job_id, {:ok, "done"}})

      Process.sleep(50)
      status = GenServer.call(pid, :status)
      assert status.running_jobs == 0

      GenServer.stop(pid)
    end

    test "Task ref and DOWN messages are handled" do
      name = :"test_scheduler_#{System.unique_integer([:positive])}"
      {:ok, pid} = GenServer.start_link(Scheduler, [], name: name)

      # These shouldn't crash the scheduler
      ref = make_ref()
      send(pid, {ref, :ok})
      send(pid, {:DOWN, ref, :process, self(), :normal})

      Process.sleep(50)
      assert Process.alive?(pid)

      GenServer.stop(pid)
    end
  end

  describe "handle_cast/2" do
    test "remove_job handles unknown job id gracefully" do
      name = :"test_scheduler_#{System.unique_integer([:positive])}"
      {:ok, pid} = GenServer.start_link(Scheduler, [], name: name)

      GenServer.cast(pid, {:remove_job, "nonexistent"})

      Process.sleep(50)
      assert Process.alive?(pid)

      GenServer.stop(pid)
    end
  end

  describe "list_scheduled/0" do
    test "returns empty list when no jobs loaded" do
      name = :"test_scheduler_#{System.unique_integer([:positive])}"
      {:ok, pid} = GenServer.start_link(Scheduler, [], name: name)

      scheduled = GenServer.call(pid, :list_scheduled)
      assert scheduled == []

      GenServer.stop(pid)
    end
  end
end
