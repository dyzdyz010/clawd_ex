defmodule ClawdExWeb.HealthControllerTest do
  use ClawdExWeb.ConnCase

  test "GET /api/health returns health status with checks", %{conn: conn} do
    conn = get(conn, ~p"/api/health")
    status_code = conn.status
    assert status_code in [200, 503]

    body = json_response(conn, status_code)
    assert %{"status" => status, "checks" => checks, "timestamp" => _} = body
    assert status in ["ok", "degraded", "error"]
    assert is_map(checks)

    Enum.each(checks, fn {_name, check} ->
      assert Map.has_key?(check, "status")
      assert Map.has_key?(check, "details")
    end)
  end
end
