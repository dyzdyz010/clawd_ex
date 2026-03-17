defmodule ClawdExWeb.HealthController do
  @moduledoc """
  Health check HTTP endpoint.
  Returns 200 when healthy, 503 when unhealthy.
  """
  use ClawdExWeb, :controller

  def index(conn, _params) do
    result = ClawdEx.Health.full_check()

    status_code = if result.healthy, do: 200, else: 503

    conn
    |> put_status(status_code)
    |> json(%{
      status: if(result.healthy, do: "healthy", else: "unhealthy"),
      checks: format_checks(result.checks),
      timestamp: DateTime.to_iso8601(result.timestamp)
    })
  end

  defp format_checks(checks) do
    Map.new(checks, fn {name, check} ->
      {name, %{status: check.status, details: Map.get(check, :message, nil)}}
    end)
  end
end
