defmodule ClawdExWeb.HealthControllerTest do
  use ClawdExWeb.ConnCase

  describe "GET /api/health" do
    test "returns health status as JSON", %{conn: conn} do
      conn = get(conn, ~p"/api/health")
      # Status may be 200 or 503 depending on environment (e.g. no AI API keys)
      status_code = conn.status
      assert status_code in [200, 503]

      body = json_response(conn, status_code)
      assert %{"status" => status, "checks" => checks} = body
      assert status in ["ok", "degraded", "error"]
      assert is_map(checks)
    end

    test "includes check details and timestamp in response", %{conn: conn} do
      conn = get(conn, ~p"/api/health")
      status_code = conn.status
      body = json_response(conn, status_code)

      assert Map.has_key?(body, "timestamp")
      assert Map.has_key?(body, "checks")

      # Each check should have status and details keys
      Enum.each(body["checks"], fn {_name, check} ->
        assert Map.has_key?(check, "status")
        assert Map.has_key?(check, "details")
      end)
    end
  end
end
