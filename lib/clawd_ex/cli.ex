defmodule ClawdEx.CLI do
  @moduledoc """
  CLI entry point for ClawdEx commands.

  Usage:
    clawd_ex status    - Show application status
    clawd_ex health    - Run health checks
    clawd_ex configure - Interactive configuration
    clawd_ex start     - Start the application
    clawd_ex stop      - Stop the application
  """

  alias ClawdEx.CLI.{Status, Health, Configure}

  def main(args \\ []) do
    {opts, args, _} =
      OptionParser.parse(args,
        switches: [
          help: :boolean,
          verbose: :boolean,
          format: :string
        ],
        aliases: [
          h: :help,
          v: :verbose,
          f: :format
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
      start      Start the application (server mode)
      stop       Stop a running application
      version    Show version information

    Options:
      -h, --help     Show this help message
      -v, --verbose  Enable verbose output
      -f, --format   Output format (text, json)

    Examples:
      clawd_ex status
      clawd_ex health --verbose
      clawd_ex configure
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
