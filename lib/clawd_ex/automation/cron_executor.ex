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
  Wrapped in try/catch to ensure run status is always updated.
  """
  def execute(%CronJob{} = job, %CronJobRun{} = run) do
    Logger.info("Executing cron job: #{job.name} (#{job.payload_type})")

    result =
      try do
        case job.payload_type do
          "system_event" -> execute_system_event(job)
          "agent_turn" -> execute_agent_turn(job)
          _ -> {:error, "Unknown payload type: #{job.payload_type}"}
        end
      rescue
        e ->
          Logger.error(
            "Cron job execution crashed: #{Exception.message(e)}\n#{Exception.format_stacktrace(__STACKTRACE__)}"
          )

          {:error, "Execution crashed: #{Exception.message(e)}"}
      catch
        kind, reason ->
          Logger.error("Cron job execution error: #{kind} - #{inspect(reason)}")
          {:error, "Execution error: #{kind} - #{inspect(reason)}"}
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
    Logger.debug("Job: #{inspect(job, pretty: true)}")
    session_key = job.session_key || get_default_session_key(job)

    if session_key do
      # Get or start the session with existing session_key
      execute_with_session(job, session_key, _cleanup = false)
    else
      # No session_key configured, fall back to creating a temporary session
      Logger.info("No session_key for system_event mode, creating temporary session")
      run_id = :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
      temp_session_key = "cron:#{job.id}:#{run_id}"
      execute_with_session(job, temp_session_key, _cleanup = true)
    end
  end

  # Execute job with a given session key
  defp execute_with_session(job, session_key, cleanup) do
    opts = [session_key: session_key, channel: "cron"]
    opts = if job.agent_id, do: Keyword.put(opts, :agent_id, job.agent_id), else: opts

    case SessionManager.start_session(opts) do
      {:ok, pid} ->
        # Send the command as a message
        timeout = (job.timeout_seconds || 300) * 1000

        result =
          try do
            case GenServer.call(pid, {:send_message, job.command, []}, timeout) do
              {:ok, response} ->
                # Deliver to target channel and save to result session
                maybe_deliver_to_channel(job, response)
                {:ok, response}

              {:error, reason} ->
                {:error, reason}
            end
          catch
            :exit, {:timeout, _} ->
              Logger.warning("Cron job timed out after #{job.timeout_seconds}s")
              {:error, "Execution timed out after #{job.timeout_seconds}s"}

            :exit, {:noproc, _} ->
              Logger.warning("Session worker died during execution")
              {:error, "Session worker died during execution"}

            :exit, reason ->
              Logger.warning("GenServer.call exited: #{inspect(reason)}")
              {:error, "Session call failed: #{inspect(reason)}"}
          end

        # Cleanup temporary session if needed
        if cleanup do
          cleanup_session(session_key)
        end

        result

      {:error, reason} ->
        {:error, "Failed to get session: #{inspect(reason)}"}
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
  # Channel Delivery - New implementation with notify list
  # =============================================================================

  defp maybe_deliver_to_channel(
         %{notify: notify, result_session_key: result_session_key, name: job_name},
         response
       )
       when is_list(notify) and length(notify) > 0 do
    Logger.info("Delivering cron result to #{length(notify)} targets")

    message = format_result_message(job_name, response)

    # Send to all notify targets
    Enum.each(notify, fn
      %{"channel" => channel, "target" => target} ->
        deliver_to_target(channel, target, message)

      # Handle atom keys too
      %{channel: channel, target: target} ->
        deliver_to_target(to_string(channel), to_string(target), message)

      _ ->
        :ok
    end)

    # Also save to result session
    save_to_result_session(result_session_key, job_name, response)
  end

  defp maybe_deliver_to_channel(
         %{result_session_key: result_session_key, name: job_name},
         response
       )
       when is_binary(result_session_key) do
    # No notify targets, but save to result session
    save_to_result_session(result_session_key, job_name, response)
  end

  # Legacy fallback for old jobs without notify field
  defp maybe_deliver_to_channel(%{target_channel: nil}, _response), do: :ok
  defp maybe_deliver_to_channel(%{target_channel: ""}, _response), do: :ok

  defp maybe_deliver_to_channel(%{target_channel: channel, name: job_name}, response) do
    Logger.info("Delivering cron result to legacy channel: #{channel}")

    message = format_result_message(job_name, response)

    case channel do
      "telegram" ->
        deliver_to_telegram(message)

      "discord" ->
        deliver_to_discord(message)

      "webchat" ->
        Phoenix.PubSub.broadcast(
          ClawdEx.PubSub,
          "cron:results",
          {:cron_result, job_name, response}
        )

        :ok

      _ ->
        Logger.warning("Unknown target channel: #{channel}")
        :ok
    end
  end

  defp maybe_deliver_to_channel(_, _), do: :ok

  defp format_result_message(job_name, response) do
    """
    ⏰ **定时任务完成: #{job_name}**

    #{truncate_output(response, 3500)}
    """
  end

  defp deliver_to_target(channel, target, message) do
    Logger.info("Sending to #{channel}:#{target}")

    case channel do
      "telegram" ->
        ClawdEx.Channels.Telegram.send_message(target, message)

      "discord" ->
        ClawdEx.Channels.Discord.send_message(target, message)

      _ ->
        Logger.warning("Unknown channel type: #{channel}")
        :ok
    end
  rescue
    e ->
      Logger.error("Failed to deliver to #{channel}:#{target}: #{Exception.message(e)}")
      :ok
  end

  defp save_to_result_session(nil, _job_name, _response), do: :ok
  defp save_to_result_session("", _job_name, _response), do: :ok

  defp save_to_result_session(result_session_key, job_name, response) do
    Logger.info("Saving result to session: #{result_session_key}")

    # Ensure session exists in database
    session = ensure_result_session(result_session_key)

    # Save the result as an assistant message
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

    result_message = """
    📋 **#{job_name}** - #{timestamp}

    #{response}
    """

    # Insert message directly to database
    %ClawdEx.Sessions.Message{}
    |> ClawdEx.Sessions.Message.changeset(%{
      session_id: session.id,
      role: :assistant,
      content: result_message
    })
    |> Repo.insert()
    |> case do
      {:ok, _msg} ->
        Logger.debug("Result saved to session #{result_session_key}")
        :ok

      {:error, reason} ->
        Logger.error("Failed to save result message: #{inspect(reason)}")
        :ok
    end
  end

  defp ensure_result_session(result_session_key) do
    alias ClawdEx.Sessions.Session

    case Repo.get_by(Session, session_key: result_session_key) do
      nil ->
        # Create the result session
        %Session{}
        |> Session.changeset(%{
          session_key: result_session_key,
          channel: "cron_results",
          state: :active
        })
        |> Repo.insert!()

      session ->
        session
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
        # Convert string agent_id to integer for Session query
        # (CronJob stores agent_id as string, Session uses integer foreign key)
        case parse_agent_id(agent_id) do
          nil ->
            Logger.warning("Invalid agent_id format: #{inspect(agent_id)}")
            nil

          int_agent_id ->
            # Look for the most recent active session
            import Ecto.Query

            ClawdEx.Sessions.Session
            |> where([s], s.agent_id == ^int_agent_id and s.state == :active)
            |> order_by([s], desc: s.last_activity_at)
            |> limit(1)
            |> select([s], s.session_key)
            |> Repo.one()
        end
    end
  end

  defp parse_agent_id(agent_id) when is_integer(agent_id), do: agent_id

  defp parse_agent_id(agent_id) when is_binary(agent_id) do
    case Integer.parse(agent_id) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_agent_id(_), do: nil

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
