defmodule ClawdEx.CLI.Logs do
  @moduledoc """
  CLI logs command - view application logs.

  Usage:
    clawd_ex logs [options]

  Options:
    --level LEVEL    Filter by log level (error, warn, info, debug)
    --tail N         Show last N lines (default: 50)
  """

  @default_tail 50

  def run(args, opts \\ [])

  def run(["--help" | _], _opts), do: print_help()

  def run(args, opts) do
    if opts[:help] do
      print_help()
    else
      {parsed, _rest, _} =
        OptionParser.parse(args,
          switches: [level: :string, tail: :integer],
          aliases: [l: :level, n: :tail]
        )

      level = parsed[:level] || opts[:level]
      tail = parsed[:tail] || opts[:tail] || @default_tail

      show_logs(level, tail)
    end
  end

  # ---------------------------------------------------------------------------
  # Log display
  # ---------------------------------------------------------------------------

  defp show_logs(level, tail) do
    log_path = get_log_path()

    if File.exists?(log_path) do
      lines =
        log_path
        |> File.stream!()
        |> Stream.map(&String.trim_trailing/1)
        |> maybe_filter_level(level)
        |> Enum.to_list()
        |> take_last(tail)

      if Enum.empty?(lines) do
        IO.puts("No log entries found#{level_suffix(level)}.")
      else
        IO.puts(
          "Showing last #{length(lines)} log entries#{level_suffix(level)} from #{log_path}\n"
        )

        Enum.each(lines, &IO.puts/1)
      end
    else
      IO.puts("Log file not found: #{log_path}")
      IO.puts("Make sure the application has been started and is writing logs.")
    end
  end

  defp maybe_filter_level(stream, nil), do: stream

  defp maybe_filter_level(stream, level) do
    normalized = normalize_level(level)

    if normalized do
      pattern = "[#{normalized}]"
      Stream.filter(stream, fn line -> String.contains?(line, pattern) end)
    else
      IO.puts("Warning: unknown log level '#{level}', showing all levels.\n")
      stream
    end
  end

  defp normalize_level(level) do
    case String.downcase(level) do
      "error" -> "error"
      "warn" -> "warning"
      "warning" -> "warning"
      "info" -> "info"
      "debug" -> "debug"
      _ -> nil
    end
  end

  defp level_suffix(nil), do: ""
  defp level_suffix(level), do: " (level: #{level})"

  defp take_last(list, n) when length(list) <= n, do: list
  defp take_last(list, n), do: Enum.drop(list, length(list) - n)

  @doc false
  def get_log_path do
    Application.get_env(:clawd_ex, :log_path) || default_log_path()
  end

  defp default_log_path do
    env = Mix.env()
    "log/#{env}.log"
  end

  # ---------------------------------------------------------------------------
  # Help
  # ---------------------------------------------------------------------------

  defp print_help do
    IO.puts("""
    Usage: clawd_ex logs [options]

    View application logs.

    Options:
      --level LEVEL    Filter by log level (error, warn, info, debug)
      --tail N         Show last N lines (default: 50)
      --help           Show this help message

    Examples:
      clawd_ex logs
      clawd_ex logs --level error
      clawd_ex logs --tail 100
      clawd_ex logs --level warn --tail 20
    """)
  end
end
