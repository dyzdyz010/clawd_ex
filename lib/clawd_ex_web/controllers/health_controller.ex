defmodule ClawdExWeb.HealthController do
  @moduledoc """
  Health check HTTP endpoint.

  Returns JSON with overall status and per-subsystem check results.

  - 200 with status "ok" when all checks pass
  - 200 with status "degraded" when non-critical checks fail
  - 503 with status "error" when critical checks fail
  """
  use ClawdExWeb, :controller

  # Subsystems whose failure means the service is down, not merely degraded
  @critical_subsystems [:database]

  def index(conn, _params) do
    result = ClawdEx.Health.full_check()
    checks = format_checks(result.checks)

    status = compute_status(result.checks)
    status_code = if status == "error", do: 503, else: 200

    conn
    |> put_status(status_code)
    |> json(%{
      status: status,
      checks: checks,
      timestamp: DateTime.to_iso8601(result.timestamp)
    })
  end

  # Determine overall status from individual check results
  defp compute_status(checks) do
    has_critical_failure =
      checks
      |> Enum.any?(fn {name, check} ->
        name in @critical_subsystems and check.status != :ok
      end)

    has_any_failure =
      checks
      |> Enum.any?(fn {_name, check} -> check.status != :ok end)

    cond do
      has_critical_failure -> "error"
      has_any_failure -> "degraded"
      true -> "ok"
    end
  end

  defp format_checks(checks) do
    Map.new(checks, fn {name, check} ->
      {name, %{
        status: to_string(check.status),
        details: Map.get(check, :message, nil)
      }}
    end)
  end
end
