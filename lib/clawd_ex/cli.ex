defmodule ClawdEx.CLI do
  @moduledoc """
  CLI entry point for ClawdEx commands.

  Usage:
    clawd_ex status             - Show application status
    clawd_ex health             - Run health checks
    clawd_ex configure          - Interactive configuration
    clawd_ex sessions list      - List sessions
    clawd_ex sessions history   - View session history
    clawd_ex agents list        - List agents
    clawd_ex agents add <name>  - Create a new agent
    clawd_ex cron list          - List cron jobs
    clawd_ex cron run <id>      - Manually trigger a cron job
    clawd_ex start              - Start the application
    clawd_ex stop               - Stop the application
  """

  alias ClawdEx.CLI.{Status, Health, Configure, Sessions, Agents, Cron}

  def main(args \\ []) do
    {opts, args, _} =
      OptionParser.parse(args,
        switches: [
          help: :boolean,
          verbose: :boolean,
          format: :string,
          limit: :integer,
          model: :string,
          system_prompt: :string
        ],
        aliases: [
          h: :help,
          v: :verbose,
          f: :format,
          l: :limit
        ]
      )

    if opts[:help] do
      print_help()
    else
      run_command(args, opts)
    end
  end

  defp run_command(["status" | _rest], opts), do: Status.run(opts)
  defp run_command(["health" | _rest], opts), do: Health.run(opts)
  defp run_command(["configure" | _rest], opts), do: Configure.run(opts)
  defp run_command(["sessions" | rest], opts), do: Sessions.run(rest, opts)
  defp run_command(["agents" | rest], opts), do: Agents.run(rest, opts)
  defp run_command(["cron" | rest], opts), do: Cron.run(rest, opts)
  defp run_command(["start" | _rest], _opts), do: start_app()
  defp run_command(["stop" | _rest], _opts), do: stop_app()
  defp run_command(["version" | _rest], _opts), do: print_version()
  defp run_command([], _opts), do: print_help()

  defp run_command([cmd | _], _opts),
    do: IO.puts("Unknown command: #{cmd}\n\nRun 'clawd_ex --help' for usage.")

  defp print_help do
    IO.puts("""
    ClawdEx - Elixir AI Assistant Framework

    Usage:
      clawd_ex <command> [options]

    Commands:
      status     Show application status and health
      health     Run comprehensive health checks
      configure  Interactive configuration wizard
      sessions   Manage sessions (list, history)
      agents     Manage agents (list, add)
      cron       Manage cron jobs (list, run)
      start      Start the application (server mode)
      stop       Stop a running application
      version    Show version information

    Options:
      -h, --help     Show this help message
      -v, --verbose  Enable verbose output
      -f, --format   Output format (text, json)
      -l, --limit N  Limit number of results

    Examples:
      clawd_ex status
      clawd_ex health --verbose
      clawd_ex sessions list --limit 10
      clawd_ex sessions history my-session-key
      clawd_ex agents list
      clawd_ex agents add my-agent --model gpt-4
      clawd_ex cron list
      clawd_ex cron run <job-id>
    """)
  end

  defp print_version do
    version = Application.spec(:clawd_ex, :vsn) |> to_string()
    IO.puts("ClawdEx v#{version}")
  end

  defp start_app do
    IO.puts("Starting ClawdEx...")
    Application.ensure_all_started(:clawd_ex)
    IO.puts("ClawdEx started. Press Ctrl+C to stop.")
    Process.sleep(:infinity)
  end

  defp stop_app do
    IO.puts("Stopping ClawdEx...")
    System.stop(0)
  end
end
