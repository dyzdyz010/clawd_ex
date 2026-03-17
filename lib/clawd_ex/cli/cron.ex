defmodule ClawdEx.CLI.Cron do
  @moduledoc """
  CLI cron command - list and manage cron jobs.

  Usage:
    clawd_ex cron list
    clawd_ex cron run <id>
  """

  alias ClawdEx.Automation

  def run(args, opts \\ [])

  def run(["list" | _rest], opts) do
    if opts[:help] do
      print_list_help()
    else
      list_jobs(opts)
    end
  end

  def run(["run", id | _rest], opts) do
    if opts[:help] do
      print_run_help()
    else
      run_job(id, opts)
    end
  end

  def run(["run" | _rest], _opts) do
    IO.puts("Error: job ID is required.\n")
    print_run_help()
  end

  def run(["--help" | _], _opts), do: print_help()
  def run([], _opts), do: print_help()

  def run([subcmd | _], _opts) do
    IO.puts("Unknown cron subcommand: #{subcmd}\n")
    print_help()
  end

  # ---------------------------------------------------------------------------
  # cron list
  # ---------------------------------------------------------------------------

  defp list_jobs(_opts) do
    jobs = Automation.list_jobs()

    if Enum.empty?(jobs) do
      IO.puts("No cron jobs found.")
    else
      IO.puts("""
      ┌─────────────────────────────────────────────────────────────────────────────────┐
      │                              Cron Jobs                                         │
      └─────────────────────────────────────────────────────────────────────────────────┘
      """)

      IO.puts(
        String.pad_trailing("ID", 38) <>
          String.pad_trailing("NAME", 20) <>
          String.pad_trailing("SCHEDULE", 16) <>
          String.pad_trailing("ON", 4) <>
          String.pad_trailing("LAST RUN", 20) <>
          "NEXT RUN"
      )

      IO.puts(String.duplicate("─", 120))

      Enum.each(jobs, fn job ->
        last_run = format_datetime(job.last_run_at)
        next_run = format_datetime(job.next_run_at)

        IO.puts(
          String.pad_trailing(truncate(job.id, 36), 38) <>
            String.pad_trailing(truncate(job.name, 18), 20) <>
            String.pad_trailing(truncate(job.schedule, 14), 16) <>
            String.pad_trailing(if(job.enabled, do: "✓", else: "✗"), 4) <>
            String.pad_trailing(last_run, 20) <>
            next_run
        )
      end)

      IO.puts("")

      enabled_count = Enum.count(jobs, & &1.enabled)
      IO.puts("Total: #{length(jobs)} jobs (#{enabled_count} enabled)")
    end
  end

  # ---------------------------------------------------------------------------
  # cron run
  # ---------------------------------------------------------------------------

  defp run_job(id, _opts) do
    case Automation.get_job(id) do
      nil ->
        IO.puts("✗ Cron job not found: #{id}")

      job ->
        IO.puts("Triggering cron job: #{job.name} ...")

        case Automation.run_job_now(job, async: false) do
          {:ok, run} ->
            IO.puts("""

            ✓ Job executed successfully!

              Job:      #{job.name}
              Status:   #{run.status}
              Output:   #{truncate(run.output || run.error || "—", 200)}
            """)

          {:error, reason} ->
            IO.puts("\n✗ Job execution failed: #{inspect(reason)}")
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp format_datetime(nil), do: "—"

  defp format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  end

  defp format_datetime(_), do: "—"

  defp truncate(nil, _max), do: "—"

  defp truncate(str, max) when is_binary(str) do
    if String.length(str) > max do
      String.slice(str, 0, max - 1) <> "…"
    else
      str
    end
  end

  # ---------------------------------------------------------------------------
  # Help
  # ---------------------------------------------------------------------------

  defp print_help do
    IO.puts("""
    Usage: clawd_ex cron <subcommand> [options]

    Subcommands:
      list           List all cron jobs
      run <id>       Manually trigger a cron job

    Options:
      --help         Show this help message
    """)
  end

  defp print_list_help do
    IO.puts("""
    Usage: clawd_ex cron list [options]

    List all configured cron jobs.

    Options:
      --help    Show this help message
    """)
  end

  defp print_run_help do
    IO.puts("""
    Usage: clawd_ex cron run <id> [options]

    Manually trigger a cron job by its ID.

    Options:
      --help    Show this help message
    """)
  end
end
