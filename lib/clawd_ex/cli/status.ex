defmodule ClawdEx.CLI.Status do
  @moduledoc """
  CLI status command - shows application status and basic health.
  """

  alias ClawdEx.{Repo, Health}

  def run(opts \\ []) do
    format = Keyword.get(opts, :format, "text")
    verbose = Keyword.get(opts, :verbose, false)

    status = gather_status(verbose)

    case format do
      "json" -> output_json(status)
      _ -> output_text(status, verbose)
    end
  end

  defp gather_status(verbose) do
    %{
      app: app_status(),
      database: database_status(),
      health: Health.quick_check(),
      stats: if(verbose, do: gather_stats(), else: nil)
    }
  end

  defp app_status do
    %{
      name: "ClawdEx",
      version: Application.spec(:clawd_ex, :vsn) |> to_string(),
      environment: Application.get_env(:clawd_ex, :env, Mix.env()),
      elixir_version: System.version(),
      otp_version: :erlang.system_info(:otp_release) |> List.to_string(),
      uptime: get_uptime(),
      memory_mb: Float.round(:erlang.memory(:total) / 1024 / 1024, 1),
      process_count: :erlang.system_info(:process_count)
    }
  end

  defp database_status do
    try do
      Repo.query!("SELECT 1")
      %{connected: true, error: nil}
    rescue
      e -> %{connected: false, error: Exception.message(e)}
    end
  end

  defp gather_stats do
    %{
      agents: count_table("agents"),
      sessions: count_table("sessions"),
      messages: count_table("messages"),
      cron_jobs: count_table("cron_jobs")
    }
  end

  defp count_table(table) do
    try do
      %{rows: [[count]]} = Repo.query!("SELECT COUNT(*) FROM #{table}")
      count
    rescue
      _ -> 0
    end
  end

  defp get_uptime do
    {uptime_ms, _} = :erlang.statistics(:wall_clock)
    format_duration(uptime_ms)
  end

  defp format_duration(ms) do
    seconds = div(ms, 1000)

    cond do
      seconds < 60 -> "#{seconds}s"
      seconds < 3600 -> "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
      seconds < 86400 -> "#{div(seconds, 3600)}h #{div(rem(seconds, 3600), 60)}m"
      true -> "#{div(seconds, 86400)}d #{div(rem(seconds, 86400), 3600)}h"
    end
  end

  defp output_json(status) do
    IO.puts(Jason.encode!(status, pretty: true))
  end

  defp output_text(status, verbose) do
    IO.puts("""
    ┌─────────────────────────────────────────┐
    │           ClawdEx Status                │
    └─────────────────────────────────────────┘

    Application:
      Name:        #{status.app.name}
      Version:     #{status.app.version}
      Environment: #{status.app.environment}
      Uptime:      #{status.app.uptime}
      Memory:      #{status.app.memory_mb} MB
      Processes:   #{status.app.process_count}

    Runtime:
      Elixir:      #{status.app.elixir_version}
      OTP:         #{status.app.otp_version}

    Database:
      Status:      #{if status.database.connected, do: "✓ Connected", else: "✗ Disconnected"}
    #{if status.database.error, do: "  Error:       #{status.database.error}", else: ""}

    Health:
      Status:      #{health_status_text(status.health)}
    """)

    if verbose && status.stats do
      IO.puts("""
      Statistics:
        Agents:    #{status.stats.agents}
        Sessions:  #{status.stats.sessions}
        Messages:  #{status.stats.messages}
        Cron Jobs: #{status.stats.cron_jobs}
      """)
    end
  end

  defp health_status_text(%{healthy: true}), do: "✓ Healthy"
  defp health_status_text(%{healthy: false, issues: issues}), do: "✗ #{length(issues)} issue(s)"
  defp health_status_text(_), do: "? Unknown"
end
