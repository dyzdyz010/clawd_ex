defmodule ClawdEx.Automation.CronExecutor do
  @moduledoc """
  Executes cron jobs in two modes:
  - system_event: Injects message into existing session
  - agent_turn: Runs agent in isolated session
  """

  require Logger

  alias ClawdEx.Automation
  alias ClawdEx.Automation.{CronJob, CronJobRun}
  alias ClawdEx.Sessions.SessionManager
  alias ClawdEx.Repo

  @doc """
  Execute a cron job based on its payload_type.
  """
  def execute(%CronJob{} = job, %CronJobRun{} = run) do
    Logger.info("Executing cron job: #{job.name} (#{job.payload_type})")

    result =
      case job.payload_type do
        "system_event" -> execute_system_event(job)
        "agent_turn" -> execute_agent_turn(job)
        _ -> {:error, "Unknown payload type: #{job.payload_type}"}
      end

    # Update run status based on result
    case result do
      {:ok, output} ->
        Automation.complete_run(run, %{
          status: "completed",
          exit_code: 0,
          output: truncate_output(output)
        })

        Automation.update_job(job, %{
          last_run_at: DateTime.utc_now(),
          run_count: job.run_count + 1
        })

        {:ok, output}

      {:error, reason} ->
        Automation.complete_run(run, %{
          status: "failed",
          exit_code: 1,
          error: truncate_output(inspect(reason))
        })

        {:error, reason}
    end
  end

  # =============================================================================
  # System Event Mode
  # =============================================================================

  defp execute_system_event(job) do
    session_key = job.session_key || get_default_session_key(job)

    if session_key do
      # Get or start the session
      opts = [session_key: session_key]
      opts = if job.agent_id, do: Keyword.put(opts, :agent_id, job.agent_id), else: opts

      case SessionManager.start_session(opts) do
        {:ok, pid} ->
          # Send the command as a message
          timeout = (job.timeout_seconds || 300) * 1000

          try do
            result = GenServer.call(pid, {:send_message, job.command, []}, timeout)

            case result do
              {:ok, response} ->
                # Optionally deliver to target channel
                maybe_deliver_to_channel(job, response)
                {:ok, response}

              {:error, reason} ->
                {:error, reason}
            end
          catch
            :exit, {:timeout, _} ->
              {:error, "Execution timed out after #{job.timeout_seconds}s"}
          end

        {:error, reason} ->
          {:error, "Failed to get session: #{inspect(reason)}"}
      end
    else
      {:error, "No session_key configured for system_event mode"}
    end
  end

  # =============================================================================
  # Agent Turn Mode
  # =============================================================================

  defp execute_agent_turn(job) do
    # Generate a unique session key for this run
    run_id = :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
    session_key = "cron:#{job.id}:#{run_id}"

    try do
      # Start isolated session
      opts = [session_key: session_key, channel: "cron"]
      opts = if job.agent_id, do: Keyword.put(opts, :agent_id, job.agent_id), else: opts

      case SessionManager.start_session(opts) do
        {:ok, pid} ->
          # Execute the command
          timeout = (job.timeout_seconds || 300) * 1000

          result =
            try do
              GenServer.call(pid, {:send_message, job.command, []}, timeout)
            catch
              :exit, {:timeout, _} ->
                {:error, "Execution timed out after #{job.timeout_seconds}s"}
            end

          response =
            case result do
              {:ok, response} -> response
              {:error, reason} -> "Error: #{inspect(reason)}"
            end

          # Deliver to target channel if configured
          maybe_deliver_to_channel(job, response)

          # Cleanup if configured
          if job.cleanup == "delete" do
            cleanup_session(session_key)
          end

          {:ok, response}

        {:error, reason} ->
          {:error, "Failed to start session: #{inspect(reason)}"}
      end
    rescue
      e ->
        Logger.error("Cron job execution failed: #{Exception.message(e)}")
        {:error, Exception.message(e)}
    end
  end

  # =============================================================================
  # Channel Delivery
  # =============================================================================

  defp maybe_deliver_to_channel(%{target_channel: nil}, _response), do: :ok
  defp maybe_deliver_to_channel(%{target_channel: ""}, _response), do: :ok

  defp maybe_deliver_to_channel(%{target_channel: channel, name: job_name}, response) do
    Logger.info("Delivering cron result to channel: #{channel}")

    message = """
    ⏰ **Cron Job Complete: #{job_name}**

    #{truncate_output(response, 2000)}
    """

    case channel do
      "telegram" ->
        deliver_to_telegram(message)

      "discord" ->
        deliver_to_discord(message)

      "webchat" ->
        # For webchat, just broadcast via PubSub
        Phoenix.PubSub.broadcast(ClawdEx.PubSub, "cron:results", {:cron_result, job_name, response})
        :ok

      _ ->
        Logger.warning("Unknown target channel: #{channel}")
        :ok
    end
  end

  defp deliver_to_telegram(message) do
    # Get configured chat_id from env or config
    case Application.get_env(:clawd_ex, :telegram) do
      %{default_chat_id: chat_id} when not is_nil(chat_id) ->
        ClawdEx.Channels.Telegram.send_message(chat_id, message)

      _ ->
        Logger.warning("No default Telegram chat_id configured for cron delivery")
        :ok
    end
  end

  defp deliver_to_discord(message) do
    # Get configured channel_id from env or config
    case Application.get_env(:clawd_ex, :discord) do
      %{default_channel_id: channel_id} when not is_nil(channel_id) ->
        ClawdEx.Channels.Discord.send_message(channel_id, message)

      _ ->
        Logger.warning("No default Discord channel_id configured for cron delivery")
        :ok
    end
  end

  # =============================================================================
  # Helpers
  # =============================================================================

  defp get_default_session_key(job) do
    # Try to find an existing session for this agent
    case job.agent_id do
      nil ->
        nil

      agent_id ->
        # Look for the most recent active session
        import Ecto.Query

        ClawdEx.Sessions.Session
        |> where([s], s.agent_id == ^agent_id and s.state == :active)
        |> order_by([s], desc: s.last_activity_at)
        |> limit(1)
        |> select([s], s.session_key)
        |> Repo.one()
    end
  end

  defp cleanup_session(session_key) do
    # Archive the session
    case SessionManager.find_session(session_key) do
      {:ok, pid} ->
        GenServer.cast(pid, :archive)
        # Stop the session worker
        SessionManager.stop_session(session_key)

      :not_found ->
        :ok
    end

    # Also delete from database
    import Ecto.Query

    ClawdEx.Sessions.Session
    |> where([s], s.session_key == ^session_key)
    |> Repo.delete_all()
  end

  defp truncate_output(nil), do: ""
  defp truncate_output(output), do: truncate_output(output, 4000)

  defp truncate_output(output, max_length) when is_binary(output) do
    if String.length(output) > max_length do
      String.slice(output, 0, max_length) <> "...(truncated)"
    else
      output
    end
  end

  defp truncate_output(output, max_length), do: truncate_output(inspect(output), max_length)
end
