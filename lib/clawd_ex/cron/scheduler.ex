defmodule ClawdEx.Cron.Scheduler do
  @moduledoc """
  Cron scheduling engine.

  A GenServer that:
  - Loads active cron jobs from the database on startup
  - Computes next execution time via `ClawdEx.Cron.Parser`
  - Fires jobs when their scheduled time arrives
  - Supports dynamic add/remove/pause of jobs at runtime
  - Delegates execution to `ClawdEx.Cron.Executor`

  ## Tick Strategy

  The scheduler wakes up every minute (aligned to the minute boundary)
  and checks which jobs are due. This avoids drift and keeps resource
  usage minimal.
  """

  use GenServer
  require Logger

  alias ClawdEx.Cron.{Parser, Executor}
  alias ClawdEx.Automation
  alias ClawdEx.Automation.CronJob

  @tick_interval :timer.seconds(60)

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc "Start the scheduler."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Reload all jobs from the database."
  def reload do
    GenServer.call(__MODULE__, :reload)
  end

  @doc "Add or update a job in the scheduler (call after DB insert/update)."
  def refresh_job(job_id) do
    GenServer.cast(__MODULE__, {:refresh_job, job_id})
  end

  @doc "Remove a job from the scheduler (call after DB delete)."
  def remove_job(job_id) do
    GenServer.cast(__MODULE__, {:remove_job, job_id})
  end

  @doc "Pause a job (disable without deleting)."
  def pause_job(job_id) do
    GenServer.cast(__MODULE__, {:pause_job, job_id})
  end

  @doc "Resume a paused job."
  def resume_job(job_id) do
    GenServer.cast(__MODULE__, {:resume_job, job_id})
  end

  @doc "Get the current state of the scheduler (for debugging)."
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc "Get list of scheduled job IDs and their next run times."
  def list_scheduled do
    GenServer.call(__MODULE__, :list_scheduled)
  end

  # ---------------------------------------------------------------------------
  # GenServer Callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    Logger.info("[CronScheduler] Starting...")

    state = %{
      jobs: %{},           # job_id => %{job: CronJob, parsed: parsed_cron, next_run: DateTime}
      running: MapSet.new() # job_ids currently executing
    }

    # Load jobs after a short delay to let the Repo start
    Process.send_after(self(), :load_jobs, 1_000)

    {:ok, state}
  end

  @impl true
  def handle_info(:load_jobs, state) do
    state = load_all_jobs(state)
    schedule_next_tick()
    Logger.info("[CronScheduler] Loaded #{map_size(state.jobs)} jobs")
    {:noreply, state}
  end

  @impl true
  def handle_info(:tick, state) do
    state = process_tick(state)
    schedule_next_tick()
    {:noreply, state}
  end

  # Handle execution completion
  @impl true
  def handle_info({:job_completed, job_id, result}, state) do
    Logger.info("[CronScheduler] Job #{job_id} completed: #{inspect(result, limit: 200)}")

    state = %{state | running: MapSet.delete(state.running, job_id)}

    # Recalculate next run
    state = update_next_run(state, job_id)

    {:noreply, state}
  end

  @impl true
  def handle_info({ref, _result}, state) when is_reference(ref) do
    # Task completion message — ignore (we handle via :job_completed)
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    # Task monitor DOWN — ignore
    {:noreply, state}
  end

  @impl true
  def handle_call(:reload, _from, state) do
    state = load_all_jobs(state)
    {:reply, {:ok, map_size(state.jobs)}, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      total_jobs: map_size(state.jobs),
      running_jobs: MapSet.size(state.running),
      running_ids: MapSet.to_list(state.running),
      next_runs:
        state.jobs
        |> Enum.map(fn {id, info} -> {id, info.next_run} end)
        |> Enum.sort_by(fn {_id, next_run} -> next_run end, DateTime)
        |> Enum.take(5)
    }

    {:reply, status, state}
  end

  @impl true
  def handle_call(:list_scheduled, _from, state) do
    scheduled =
      state.jobs
      |> Enum.map(fn {id, info} ->
        %{id: id, name: info.job.name, next_run: info.next_run, enabled: info.job.enabled}
      end)
      |> Enum.sort_by(& &1.next_run, DateTime)

    {:reply, scheduled, state}
  end

  @impl true
  def handle_cast({:refresh_job, job_id}, state) do
    state =
      case Automation.get_job(job_id) do
        nil ->
          # Job was deleted
          %{state | jobs: Map.delete(state.jobs, job_id)}

        job ->
          if job.enabled do
            load_job(state, job)
          else
            %{state | jobs: Map.delete(state.jobs, job_id)}
          end
      end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:remove_job, job_id}, state) do
    {:noreply, %{state | jobs: Map.delete(state.jobs, job_id)}}
  end

  @impl true
  def handle_cast({:pause_job, job_id}, state) do
    case Automation.get_job(job_id) do
      nil -> :ok
      job -> Automation.update_job(job, %{enabled: false})
    end

    {:noreply, %{state | jobs: Map.delete(state.jobs, job_id)}}
  end

  @impl true
  def handle_cast({:resume_job, job_id}, state) do
    case Automation.get_job(job_id) do
      nil ->
        {:noreply, state}

      job ->
        Automation.update_job(job, %{enabled: true})
        {:noreply, load_job(state, %{job | enabled: true})}
    end
  end

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

  defp load_all_jobs(state) do
    jobs = Automation.list_jobs(enabled_only: true)

    new_jobs =
      Enum.reduce(jobs, %{}, fn job, acc ->
        case parse_and_schedule(job) do
          {:ok, info} -> Map.put(acc, job.id, info)
          {:error, reason} ->
            Logger.warning("[CronScheduler] Skipping job #{job.id} (#{job.name}): #{reason}")
            acc
        end
      end)

    %{state | jobs: new_jobs}
  end

  defp load_job(state, %CronJob{} = job) do
    case parse_and_schedule(job) do
      {:ok, info} ->
        %{state | jobs: Map.put(state.jobs, job.id, info)}

      {:error, reason} ->
        Logger.warning("[CronScheduler] Failed to load job #{job.id}: #{reason}")
        state
    end
  end

  defp parse_and_schedule(%CronJob{} = job) do
    # Expand shorthand expressions before parsing
    schedule = expand_shorthand(job.schedule)

    case Parser.parse(schedule) do
      {:ok, parsed} ->
        next_run = Parser.next_run(parsed)
        {:ok, %{job: job, parsed: parsed, next_run: next_run}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp expand_shorthand(schedule) do
    shorthands = %{
      "@yearly" => "0 0 1 1 *",
      "@annually" => "0 0 1 1 *",
      "@monthly" => "0 0 1 * *",
      "@weekly" => "0 0 * * 0",
      "@daily" => "0 0 * * *",
      "@midnight" => "0 0 * * *",
      "@hourly" => "0 * * * *"
    }

    Map.get(shorthands, String.downcase(String.trim(schedule)), schedule)
  end

  defp schedule_next_tick do
    # Align to the next minute boundary for consistency
    now = DateTime.utc_now()
    seconds_until_next_minute = 60 - now.second
    # Add a small buffer (1s) to ensure we're past the boundary
    delay = :timer.seconds(seconds_until_next_minute) + 1_000
    # Cap at @tick_interval to avoid edge cases
    delay = min(delay, @tick_interval + 1_000)
    Process.send_after(self(), :tick, delay)
  end

  defp process_tick(state) do
    now = DateTime.utc_now()

    {to_run, state} =
      Enum.reduce(state.jobs, {[], state}, fn {job_id, info}, {acc, s} ->
        if should_run?(info, now, s.running) do
          {[{job_id, info} | acc], s}
        else
          {acc, s}
        end
      end)

    # Spawn execution for each due job
    Enum.reduce(to_run, state, fn {job_id, info}, s ->
      spawn_execution(job_id, info, s)
    end)
  end

  defp should_run?(info, now, running) do
    # Job is due if next_run <= now and not already running
    not MapSet.member?(running, info.job.id) and
      DateTime.compare(info.next_run, now) in [:lt, :eq]
  end

  defp spawn_execution(job_id, info, state) do
    scheduler_pid = self()

    # Reload job from DB to get fresh state
    job = Automation.get_job(job_id) || info.job

    Task.Supervisor.async_nolink(ClawdEx.AgentTaskSupervisor, fn ->
      result = Executor.execute(job)
      send(scheduler_pid, {:job_completed, job_id, result})
      result
    end)

    %{state | running: MapSet.put(state.running, job_id)}
  end

  defp update_next_run(state, job_id) do
    case Map.get(state.jobs, job_id) do
      nil ->
        state

      info ->
        next_run = Parser.next_run(info.parsed)

        updated_info = %{info | next_run: next_run}
        %{state | jobs: Map.put(state.jobs, job_id, updated_info)}
    end
  end
end
