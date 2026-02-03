defmodule ClawdEx.Automation do
  @moduledoc """
  Automation context - Cron jobs management
  """

  import Ecto.Query
  alias ClawdEx.Repo
  alias ClawdEx.Automation.{CronJob, CronJobRun}

  # =============================================================================
  # Cron Jobs
  # =============================================================================

  @doc """
  List all cron jobs with optional filters.
  """
  def list_jobs(opts \\ []) do
    query = from(j in CronJob, order_by: [desc: j.updated_at])

    query =
      if Keyword.get(opts, :enabled_only, false) do
        where(query, [j], j.enabled == true)
      else
        query
      end

    query =
      if agent_id = Keyword.get(opts, :agent_id) do
        where(query, [j], j.agent_id == ^agent_id)
      else
        query
      end

    query =
      case Keyword.get(opts, :preload) do
        nil -> query
        preloads -> preload(query, ^preloads)
      end

    Repo.all(query)
  end

  @doc """
  Get a single cron job by ID.
  """
  def get_job(id) do
    Repo.get(CronJob, id)
  end

  @doc """
  Get a cron job with preloaded runs.
  """
  def get_job_with_runs(id, run_limit \\ 20) do
    runs_query = from(r in CronJobRun, order_by: [desc: r.started_at], limit: ^run_limit)

    CronJob
    |> Repo.get(id)
    |> Repo.preload(runs: runs_query)
  end

  @doc """
  Create a new cron job.
  """
  def create_job(attrs) do
    %CronJob{}
    |> CronJob.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Update an existing cron job.
  """
  def update_job(%CronJob{} = job, attrs) do
    job
    |> CronJob.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Delete a cron job.
  """
  def delete_job(%CronJob{} = job) do
    Repo.delete(job)
  end

  @doc """
  Toggle job enabled status.
  """
  def toggle_job(%CronJob{} = job) do
    update_job(job, %{enabled: !job.enabled})
  end

  @doc """
  Get changeset for a cron job.
  """
  def change_job(%CronJob{} = job, attrs \\ %{}) do
    CronJob.changeset(job, attrs)
  end

  # =============================================================================
  # Cron Job Runs
  # =============================================================================

  @doc """
  List runs for a specific job.
  """
  def list_runs(job_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    from(r in CronJobRun,
      where: r.job_id == ^job_id,
      order_by: [desc: r.started_at],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc """
  Get a single run by ID.
  """
  def get_run(id) do
    Repo.get(CronJobRun, id)
  end

  @doc """
  Create a run record (when job starts).
  """
  def create_run(attrs) do
    %CronJobRun{}
    |> CronJobRun.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Complete a run (mark as finished).
  """
  def complete_run(%CronJobRun{} = run, attrs) do
    finished_at = Map.get(attrs, :finished_at, DateTime.utc_now())
    duration_ms = DateTime.diff(finished_at, run.started_at, :millisecond)

    attrs =
      attrs
      |> Map.put(:finished_at, finished_at)
      |> Map.put(:duration_ms, duration_ms)

    run
    |> CronJobRun.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Run a job manually (creates a run record and executes).
  """
  def run_job_now(%CronJob{} = job) do
    with {:ok, run} <-
           create_run(%{
             job_id: job.id,
             started_at: DateTime.utc_now(),
             status: "running"
           }) do
      # Execute the job asynchronously
      Task.start(fn ->
        execute_job(job, run)
      end)

      {:ok, run}
    end
  end

  defp execute_job(job, run) do
    # Use CronExecutor for real execution
    ClawdEx.Automation.CronExecutor.execute(job, run)
  end

  # =============================================================================
  # Stats
  # =============================================================================

  @doc """
  Get job statistics.
  """
  def get_stats do
    total = Repo.aggregate(CronJob, :count)
    enabled = Repo.aggregate(from(j in CronJob, where: j.enabled), :count)
    total_runs = Repo.aggregate(CronJobRun, :count)

    failed_runs =
      Repo.aggregate(from(r in CronJobRun, where: r.status == "failed"), :count)

    %{
      total_jobs: total,
      enabled_jobs: enabled,
      disabled_jobs: total - enabled,
      total_runs: total_runs,
      failed_runs: failed_runs
    }
  end
end
