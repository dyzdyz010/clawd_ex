defmodule ClawdEx.Tools.Cron do
  @moduledoc """
  Cron 工具

  管理定时任务的增删改查。
  """

  require Logger

  alias ClawdEx.Automation.CronJob
  alias ClawdEx.Repo

  import Ecto.Query

  @behaviour ClawdEx.Tools.Tool

  @impl true
  def name, do: "cron"

  @impl true
  def description do
    "Manage cron jobs: list, add, update, remove, run, and check status"
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        action: %{
          type: "string",
          enum: ["status", "list", "add", "update", "remove", "run", "runs"],
          description: "Cron action to perform"
        },
        jobId: %{
          type: "string",
          description: "Job ID for update/remove/run actions"
        },
        job: %{
          type: "object",
          description: "Job specification for add action",
          properties: %{
            name: %{type: "string"},
            schedule: %{type: "string", description: "Cron expression"},
            text: %{type: "string", description: "Task text/prompt"},
            enabled: %{type: "boolean"}
          }
        },
        patch: %{
          type: "object",
          description: "Partial update for update action"
        },
        includeDisabled: %{
          type: "boolean",
          description: "Include disabled jobs in list"
        }
      },
      required: ["action"]
    }
  end

  @impl true
  def execute(params, context) do
    action = Map.get(params, "action")
    agent_id = get_in(context, [:agent, :id])

    case action do
      "status" -> get_status(agent_id)
      "list" -> list_jobs(agent_id, params)
      "add" -> add_job(agent_id, params, context)
      "update" -> update_job(agent_id, params)
      "remove" -> remove_job(agent_id, params)
      "run" -> run_job(agent_id, params)
      "runs" -> list_runs(agent_id, params)
      _ -> {:error, "Unknown action: #{action}"}
    end
  end

  # ============================================================================
  # Actions
  # ============================================================================

  defp get_status(agent_id) do
    total = CronJob |> filter_by_agent(agent_id) |> Repo.aggregate(:count)

    enabled =
      CronJob
      |> filter_by_agent(agent_id)
      |> where([j], j.enabled == true)
      |> Repo.aggregate(:count)

    next_job =
      CronJob
      |> filter_by_agent(agent_id)
      |> where([j], j.enabled == true)
      |> order_by([j], asc: j.next_run_at)
      |> limit(1)
      |> Repo.one()

    {:ok,
     %{
       total_jobs: total,
       enabled_jobs: enabled,
       next_run:
         next_job &&
           %{
             id: next_job.id,
             name: next_job.name,
             next_run_at: next_job.next_run_at
           }
     }}
  end

  defp list_jobs(agent_id, params) do
    include_disabled = Map.get(params, "includeDisabled", false)

    query =
      CronJob
      |> filter_by_agent(agent_id)
      |> order_by([j], asc: j.next_run_at)

    query =
      if include_disabled do
        query
      else
        where(query, [j], j.enabled == true)
      end

    jobs = Repo.all(query) |> Enum.map(&job_to_map/1)

    {:ok, %{jobs: jobs}}
  end

  defp add_job(agent_id, params, context) do
    job_spec = Map.get(params, "job", %{})

    # Auto-capture channel context for notifications
    {notify, result_session_key} = build_notify_config(context, job_spec)

    attrs = %{
      agent_id: agent_id,
      name: Map.get(job_spec, "name", "Unnamed Job"),
      schedule: Map.get(job_spec, "schedule", "0 * * * *"),
      text: Map.get(job_spec, "text", ""),
      enabled: Map.get(job_spec, "enabled", true),
      notify: notify,
      result_session_key: result_session_key
    }

    case %CronJob{} |> CronJob.changeset(attrs) |> Repo.insert() do
      {:ok, job} ->
        {:ok, %{job: job_to_map(job), notify: notify, result_session_key: result_session_key}}

      {:error, changeset} ->
        {:error, "Failed to create job: #{inspect(changeset.errors)}"}
    end
  end

  defp update_job(agent_id, params) do
    job_id = Map.get(params, "jobId")
    patch = Map.get(params, "patch", %{})

    case get_job(agent_id, job_id) do
      nil ->
        {:error, "Job not found"}

      job ->
        case job |> CronJob.changeset(patch) |> Repo.update() do
          {:ok, updated} ->
            {:ok, %{job: job_to_map(updated)}}

          {:error, changeset} ->
            {:error, "Failed to update job: #{inspect(changeset.errors)}"}
        end
    end
  end

  defp remove_job(agent_id, params) do
    job_id = Map.get(params, "jobId")

    case get_job(agent_id, job_id) do
      nil ->
        {:error, "Job not found"}

      job ->
        case Repo.delete(job) do
          {:ok, _} ->
            {:ok, %{deleted: true, id: job_id}}

          {:error, reason} ->
            {:error, "Failed to delete job: #{inspect(reason)}"}
        end
    end
  end

  defp run_job(agent_id, params) do
    job_id = Map.get(params, "jobId")

    case get_job(agent_id, job_id) do
      nil ->
        {:error, "Job not found"}

      job ->
        case ClawdEx.Automation.run_job_now(job) do
          {:ok, run} ->
            {:ok,
             %{
               triggered: true,
               run_id: run.id,
               job: job_to_map(job),
               message: "Job execution triggered"
             }}

          {:error, reason} ->
            {:error, "Failed to run job: #{inspect(reason)}"}
        end
    end
  end

  defp list_runs(agent_id, params) do
    job_id = Map.get(params, "jobId")
    limit = Map.get(params, "limit", 10)

    base_query =
      from(r in ClawdEx.Automation.CronJobRun,
        join: j in CronJob,
        on: r.job_id == j.id,
        order_by: [desc: r.started_at],
        limit: ^limit,
        select: r
      )

    # Filter by agent_id (handle nil case)
    query =
      if is_nil(agent_id) do
        where(base_query, [r, j], is_nil(j.agent_id))
      else
        where(base_query, [r, j], j.agent_id == ^agent_id)
      end

    query =
      if job_id do
        where(query, [r], r.job_id == ^job_id)
      else
        query
      end

    runs = Repo.all(query) |> Enum.map(&run_to_map/1)

    {:ok, %{runs: runs}}
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp get_job(agent_id, job_id) do
    CronJob
    |> where([j], j.id == ^job_id)
    |> filter_by_agent(agent_id)
    |> Repo.one()
  end

  # Filter query by agent_id, handling nil case properly
  defp filter_by_agent(query, nil) do
    where(query, [j], is_nil(j.agent_id))
  end

  defp filter_by_agent(query, agent_id) do
    where(query, [j], j.agent_id == ^agent_id)
  end

  # Build notification config from session context
  # Automatically captures the channel/target from where the job is created
  defp build_notify_config(context, job_spec) do
    channel = get_in(context, [:session, :channel]) || get_in(context, [:channel])
    session_key = get_in(context, [:session, :session_key]) || get_in(context, [:session_key])

    # Parse additional notify targets from job_spec if provided
    extra_notify = Map.get(job_spec, "notify", [])
    extra_notify = normalize_notify_list(extra_notify)

    case channel do
      ch when ch in ["telegram", "discord"] ->
        # For push-capable channels, extract target from session_key
        # Session key format: "telegram:123456" or "discord:channel_id"
        target = extract_target_from_session(session_key, ch)

        auto_notify =
          if target do
            [%{"channel" => ch, "target" => target, "auto" => true}]
          else
            []
          end

        # Create a result session for viewing history
        result_session_key =
          "cron:results:#{:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)}"

        {merge_notify(auto_notify, extra_notify), result_session_key}

      "webchat" ->
        # For webchat, create a dedicated result session
        result_session_key =
          "cron:results:#{:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)}"

        {extra_notify, result_session_key}

      _ ->
        # Unknown or no channel
        result_session_key =
          "cron:results:#{:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)}"

        {extra_notify, result_session_key}
    end
  end

  defp extract_target_from_session(nil, _channel), do: nil

  defp extract_target_from_session(session_key, channel) do
    # Expected format: "channel:target" or "channel:target:suffix"
    case String.split(session_key, ":", parts: 3) do
      [^channel, target | _] -> target
      _ -> nil
    end
  end

  defp normalize_notify_list(list) when is_list(list) do
    Enum.map(list, fn
      %{"channel" => _, "target" => _} = item -> Map.put_new(item, "auto", false)
      item when is_map(item) -> item
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_notify_list(_), do: []

  defp merge_notify(auto, extra) do
    # Deduplicate by channel+target
    all = auto ++ extra

    all
    |> Enum.uniq_by(fn %{"channel" => c, "target" => t} -> {c, t} end)
  end

  defp job_to_map(job) do
    %{
      id: job.id,
      name: job.name,
      schedule: job.schedule,
      text: job.command,
      enabled: job.enabled,
      next_run_at: job.next_run_at,
      last_run_at: job.last_run_at,
      inserted_at: job.inserted_at,
      notify: job.notify,
      result_session_key: job.result_session_key
    }
  end

  defp run_to_map(run) do
    %{
      id: run.id,
      job_id: run.job_id,
      status: run.status,
      started_at: run.started_at,
      finished_at: run.finished_at,
      error: run.error
    }
  end
end
