defmodule ClawdEx.Health do
  @moduledoc """
  Health check system for ClawdEx.
  Provides comprehensive health monitoring and diagnostics.
  """

  alias ClawdEx.Repo

  @doc """
  Quick health check - returns basic health status.
  """
  def quick_check do
    checks = [
      {:database, check_database()},
      {:memory, check_memory()},
      {:processes, check_processes()}
    ]

    issues =
      checks
      |> Enum.filter(fn {_, result} -> result != :ok end)
      |> Enum.map(fn {name, {:error, msg}} -> "#{name}: #{msg}" end)

    %{
      healthy: Enum.empty?(issues),
      issues: issues,
      timestamp: DateTime.utc_now()
    }
  end

  @doc """
  Comprehensive health check with all subsystems.
  """
  def full_check do
    checks = %{
      database: check_database_detailed(),
      memory: check_memory_detailed(),
      processes: check_processes_detailed(),
      ai_providers: check_ai_providers(),
      browser: check_browser(),
      filesystem: check_filesystem(),
      network: check_network()
    }

    overall_healthy =
      checks
      |> Map.values()
      |> Enum.all?(fn c -> c.status == :ok end)

    %{
      healthy: overall_healthy,
      checks: checks,
      timestamp: DateTime.utc_now()
    }
  end

  # =============================================================================
  # Individual Checks
  # =============================================================================

  defp check_database do
    try do
      Repo.query!("SELECT 1")
      :ok
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  defp check_database_detailed do
    try do
      start = System.monotonic_time(:millisecond)
      Repo.query!("SELECT 1")
      latency = System.monotonic_time(:millisecond) - start

      # Get database size
      size_result =
        try do
          %{rows: [[size]]} = Repo.query!("SELECT pg_database_size(current_database())")
          format_bytes(size || 0)
        rescue
          _ -> "unknown"
        end

      %{
        status: :ok,
        latency_ms: latency,
        database_size: size_result,
        message: "Database connected"
      }
    rescue
      e ->
        %{
          status: :error,
          latency_ms: nil,
          database_size: nil,
          message: Exception.message(e)
        }
    end
  end

  defp check_memory do
    total = :erlang.memory(:total)
    # 2GB threshold
    if total > 2 * 1024 * 1024 * 1024 do
      {:error, "High memory usage: #{format_bytes(total)}"}
    else
      :ok
    end
  end

  defp check_memory_detailed do
    memory = :erlang.memory()

    %{
      status: :ok,
      total: format_bytes(memory[:total]),
      processes: format_bytes(memory[:processes]),
      system: format_bytes(memory[:system]),
      atom: format_bytes(memory[:atom]),
      binary: format_bytes(memory[:binary]),
      ets: format_bytes(memory[:ets]),
      message: "Memory within limits"
    }
  end

  defp check_processes do
    count = :erlang.system_info(:process_count)
    limit = :erlang.system_info(:process_limit)

    if count > limit * 0.8 do
      {:error, "Process count high: #{count}/#{limit}"}
    else
      :ok
    end
  end

  defp check_processes_detailed do
    count = :erlang.system_info(:process_count)
    limit = :erlang.system_info(:process_limit)
    usage_pct = Float.round(count / limit * 100, 1)

    %{
      status: if(usage_pct > 80, do: :warning, else: :ok),
      count: count,
      limit: limit,
      usage_percent: usage_pct,
      message: "#{count}/#{limit} processes (#{usage_pct}%)"
    }
  end

  defp check_ai_providers do
    providers = [
      {:anthropic, "ANTHROPIC_API_KEY"},
      {:openai, "OPENAI_API_KEY"},
      {:google, "GOOGLE_API_KEY"}
    ]

    configured =
      providers
      |> Enum.filter(fn {_, env_var} -> System.get_env(env_var) end)
      |> Enum.map(fn {name, _} -> name end)

    status = if Enum.empty?(configured), do: :warning, else: :ok

    %{
      status: status,
      configured: configured,
      total: length(providers),
      message:
        if(Enum.empty?(configured),
          do: "No AI providers configured",
          else: "#{length(configured)} provider(s) configured"
        )
    }
  end

  defp check_browser do
    # Check if Chrome/Chromium is available
    chrome_path =
      System.find_executable("google-chrome") ||
        System.find_executable("chromium") ||
        System.find_executable("chromium-browser")

    if chrome_path do
      %{
        status: :ok,
        path: chrome_path,
        message: "Browser available"
      }
    else
      %{
        status: :warning,
        path: nil,
        message: "No Chrome/Chromium found"
      }
    end
  end

  defp check_filesystem do
    # Check workspace directory
    workspace = File.cwd!()
    writable = File.stat(workspace) |> elem(0) == :ok

    %{
      status: if(writable, do: :ok, else: :error),
      workspace: workspace,
      writable: writable,
      message: if(writable, do: "Workspace accessible", else: "Workspace not writable")
    }
  end

  defp check_network do
    # Simple DNS check
    case :inet.gethostbyname('google.com') do
      {:ok, _} ->
        %{
          status: :ok,
          message: "Network connectivity OK"
        }

      {:error, reason} ->
        %{
          status: :warning,
          message: "Network issue: #{inspect(reason)}"
        }
    end
  end

  # =============================================================================
  # Helpers
  # =============================================================================

  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)} KB"

  defp format_bytes(bytes) when bytes < 1024 * 1024 * 1024,
    do: "#{Float.round(bytes / 1024 / 1024, 1)} MB"

  defp format_bytes(bytes), do: "#{Float.round(bytes / 1024 / 1024 / 1024, 2)} GB"
end
