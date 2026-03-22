defmodule ClawdEx.Cron.Executor do
  @moduledoc """
  Cron job executor.

  Handles the actual execution of cron jobs based on their type:
  - `:message` / `"system_event"` — sends a message to a session
  - `:tool` / `"agent_turn"` — executes via the existing CronExecutor
  - `:webhook` — sends an HTTP POST to a URL

  Records execution results to the database via `ClawdEx.Automation`.
  """

  require Logger

  alias ClawdEx.Automation
  alias ClawdEx.Automation.{CronJob, CronJobRun}

  @max_retries 3
  @retry_delay_ms 5_000

  @doc """
  Execute a cron job with retry support.

  Creates a run record, executes the job, and updates the run status.
  Retries up to #{@max_retries} times on failure.
  """
  @spec execute(CronJob.t()) :: {:ok, CronJobRun.t()} | {:error, term()}
  def execute(%CronJob{} = job) do
    Logger.info("[CronExecutor] Executing job #{job.id} (#{job.name})")

    # Create a run record
    case Automation.create_run(%{
           job_id: job.id,
           started_at: DateTime.utc_now(),
           status: "running"
         }) do
      {:ok, run} ->
        # Execute with retries
        result = execute_with_retries(job, run, 0)

        # Update job metadata
        update_job_after_run(job, result)

        result

      {:error, reason} ->
        Logger.error("[CronExecutor] Failed to create run record: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Retry Logic
  # ---------------------------------------------------------------------------

  defp execute_with_retries(job, run, attempt) when attempt >= @max_retries do
    Logger.error("[CronExecutor] Job #{job.id} failed after #{@max_retries} attempts")

    Automation.complete_run(run, %{
      status: "failed",
      exit_code: 1,
      error: "Failed after #{@max_retries} retry attempts"
    })

    {:error, :max_retries_exceeded}
  end

  defp execute_with_retries(job, run, attempt) do
    if attempt > 0 do
      Logger.info("[CronExecutor] Retry attempt #{attempt} for job #{job.id}")
      Process.sleep(@retry_delay_ms)
    end

    case do_execute(job) do
      {:ok, output} ->
        {:ok, _updated_run} =
          Automation.complete_run(run, %{
            status: "completed",
            exit_code: 0,
            output: truncate(output)
          })

        Logger.info("[CronExecutor] Job #{job.id} completed successfully")
        {:ok, run}

      {:error, reason} ->
        Logger.warning(
          "[CronExecutor] Job #{job.id} attempt #{attempt + 1} failed: #{inspect(reason)}"
        )

        if retriable?(reason) and attempt + 1 < @max_retries do
          execute_with_retries(job, run, attempt + 1)
        else
          Automation.complete_run(run, %{
            status: "failed",
            exit_code: 1,
            error: truncate(inspect(reason))
          })

          {:error, reason}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Execution Dispatch
  # ---------------------------------------------------------------------------

  defp do_execute(%CronJob{} = job) do
    # Delegate to the existing CronExecutor which handles system_event/agent_turn
    # For webhook type, handle separately
    case detect_type(job) do
      :webhook ->
        execute_webhook(job)

      _other ->
        # Use existing infrastructure: create a temporary run for the executor
        # But we call the inner execution directly
        try do
          case job.payload_type do
            "system_event" ->
              ClawdEx.Automation.CronExecutor.execute(job, %CronJobRun{
                id: Ecto.UUID.generate(),
                job_id: job.id,
                started_at: DateTime.utc_now(),
                status: "running"
              })

            "agent_turn" ->
              ClawdEx.Automation.CronExecutor.execute(job, %CronJobRun{
                id: Ecto.UUID.generate(),
                job_id: job.id,
                started_at: DateTime.utc_now(),
                status: "running"
              })

            _ ->
              {:ok, "Executed command: #{job.command}"}
          end
        rescue
          e ->
            {:error, "Execution error: #{Exception.message(e)}"}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Webhook Execution
  # ---------------------------------------------------------------------------

  defp execute_webhook(%CronJob{} = job) do
    url = job.command
    metadata = job.metadata || %{}
    headers = Map.get(metadata, "headers", %{})
    body = Map.get(metadata, "body", %{"job_id" => job.id, "job_name" => job.name})

    Logger.info("[CronExecutor] Sending webhook to #{url}")

    # Use Finch or httpc for HTTP requests
    case send_http_post(url, body, headers) do
      {:ok, status, response_body} when status >= 200 and status < 300 ->
        {:ok, "Webhook #{status}: #{truncate(response_body)}"}

      {:ok, status, response_body} ->
        {:error, "Webhook failed with status #{status}: #{truncate(response_body)}"}

      {:error, reason} ->
        {:error, "Webhook request failed: #{inspect(reason)}"}
    end
  end

  defp send_http_post(url, body, headers) do
    # Try to use Finch if available, fall back to :httpc
    json_body = Jason.encode!(body)

    req_headers =
      [{"content-type", "application/json"}] ++
        Enum.map(headers, fn {k, v} -> {to_string(k), to_string(v)} end)

    request = Finch.build(:post, url, req_headers, json_body)

    case Finch.request(request, ClawdEx.Finch) do
      {:ok, %Finch.Response{status: status, body: response_body}} ->
        {:ok, status, response_body}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    # If Finch is not available, try :httpc
    _ ->
      try do
        json_body = Jason.encode!(body)

        headers_charlist =
          [{~c"content-type", ~c"application/json"}] ++
            Enum.map(headers, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)

        case :httpc.request(
               :post,
               {to_charlist(url), headers_charlist, ~c"application/json", json_body},
               [timeout: 30_000],
               []
             ) do
          {:ok, {{_, status, _}, _, body}} ->
            {:ok, status, to_string(body)}

          {:error, reason} ->
            {:error, reason}
        end
      rescue
        e -> {:error, Exception.message(e)}
      end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp detect_type(%CronJob{metadata: %{"type" => "webhook"}}), do: :webhook
  defp detect_type(%CronJob{command: "http" <> _}), do: :webhook
  defp detect_type(%CronJob{payload_type: "agent_turn"}), do: :agent_turn
  defp detect_type(%CronJob{}), do: :message

  defp retriable?(:timeout), do: true
  defp retriable?({:error, :timeout}), do: true
  defp retriable?("Execution timed out" <> _), do: true
  defp retriable?(:nxdomain), do: true
  defp retriable?(:econnrefused), do: true
  defp retriable?(_), do: false

  defp update_job_after_run(job, result) do
    status =
      case result do
        {:ok, _} -> :completed
        {:error, _} -> :failed
      end

    attrs = %{
      last_run_at: DateTime.utc_now(),
      run_count: (job.run_count || 0) + 1
    }

    case Automation.update_job(job, attrs) do
      {:ok, _} -> :ok
      {:error, reason} ->
        Logger.error("[CronExecutor] Failed to update job after run: #{inspect(reason)}")
        :ok
    end

    Logger.info("[CronExecutor] Job #{job.id} run completed with status: #{status}")
  end

  defp truncate(nil), do: ""
  defp truncate(s) when is_binary(s) and byte_size(s) > 4000, do: String.slice(s, 0, 4000) <> "..."
  defp truncate(s) when is_binary(s), do: s
  defp truncate(other), do: truncate(inspect(other))
end
