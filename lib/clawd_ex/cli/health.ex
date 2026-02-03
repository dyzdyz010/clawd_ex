defmodule ClawdEx.CLI.Health do
  @moduledoc """
  CLI health command - comprehensive health checks.
  """

  alias ClawdEx.Health

  def run(opts \\ []) do
    format = Keyword.get(opts, :format, "text")
    verbose = Keyword.get(opts, :verbose, false)

    IO.puts("Running health checks...")
    IO.puts("")

    result = Health.full_check()

    case format do
      "json" -> output_json(result)
      _ -> output_text(result, verbose)
    end

    # Exit code based on health
    if result.healthy, do: 0, else: 1
  end

  defp output_json(result) do
    IO.puts(Jason.encode!(result, pretty: true))
  end

  defp output_text(result, verbose) do
    IO.puts("""
    ┌─────────────────────────────────────────┐
    │         ClawdEx Health Check            │
    └─────────────────────────────────────────┘
    """)

    # Database
    db = result.checks.database
    IO.puts("  #{status_icon(db.status)} Database")
    IO.puts("      #{db.message}")

    if verbose && db.latency_ms do
      IO.puts("      Latency: #{db.latency_ms}ms")
      IO.puts("      Size: #{db.database_size}")
    end

    IO.puts("")

    # Memory
    mem = result.checks.memory
    IO.puts("  #{status_icon(mem.status)} Memory")
    IO.puts("      #{mem.message}")

    if verbose do
      IO.puts("      Total: #{mem.total}")
      IO.puts("      Processes: #{mem.processes}")
      IO.puts("      System: #{mem.system}")
    end

    IO.puts("")

    # Processes
    proc = result.checks.processes
    IO.puts("  #{status_icon(proc.status)} Processes")
    IO.puts("      #{proc.message}")
    IO.puts("")

    # AI Providers
    ai = result.checks.ai_providers
    IO.puts("  #{status_icon(ai.status)} AI Providers")
    IO.puts("      #{ai.message}")

    if verbose && !Enum.empty?(ai.configured) do
      IO.puts("      Configured: #{Enum.join(ai.configured, ", ")}")
    end

    IO.puts("")

    # Browser
    browser = result.checks.browser
    IO.puts("  #{status_icon(browser.status)} Browser")
    IO.puts("      #{browser.message}")

    if verbose && browser.path do
      IO.puts("      Path: #{browser.path}")
    end

    IO.puts("")

    # Filesystem
    fs = result.checks.filesystem
    IO.puts("  #{status_icon(fs.status)} Filesystem")
    IO.puts("      #{fs.message}")

    if verbose do
      IO.puts("      Workspace: #{fs.workspace}")
    end

    IO.puts("")

    # Network
    net = result.checks.network
    IO.puts("  #{status_icon(net.status)} Network")
    IO.puts("      #{net.message}")
    IO.puts("")

    # Summary
    IO.puts("─────────────────────────────────────────")

    if result.healthy do
      IO.puts("  ✓ All checks passed")
    else
      failed_count =
        result.checks
        |> Map.values()
        |> Enum.count(fn c -> c.status == :error end)

      warning_count =
        result.checks
        |> Map.values()
        |> Enum.count(fn c -> c.status == :warning end)

      IO.puts("  #{failed_count} error(s), #{warning_count} warning(s)")
    end

    IO.puts("")
  end

  defp status_icon(:ok), do: "✓"
  defp status_icon(:warning), do: "⚠"
  defp status_icon(:error), do: "✗"
  defp status_icon(_), do: "?"
end
