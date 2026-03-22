defmodule ClawdExWeb.Api.GatewayControllerTest do
  use ClawdExWeb.ConnCase

  describe "GET /api/v1/gateway/status" do
    test "returns gateway status", %{conn: conn} do
      conn = get(conn, "/api/v1/gateway/status")
      assert %{"version" => _, "uptime_seconds" => _, "sessions" => _, "agents" => _} = json_response(conn, 200)
    end

    test "includes node info", %{conn: conn} do
      conn = get(conn, "/api/v1/gateway/status")
      body = json_response(conn, 200)
      assert %{"total" => _, "connected" => _, "pending" => _} = body["nodes"]
    end

    test "includes session counts", %{conn: conn} do
      conn = get(conn, "/api/v1/gateway/status")
      body = json_response(conn, 200)
      assert %{"active" => _, "total" => _} = body["sessions"]
    end

    test "includes agent counts", %{conn: conn} do
      conn = get(conn, "/api/v1/gateway/status")
      body = json_response(conn, 200)
      assert %{"total" => _, "active" => _} = body["agents"]
    end
  end

  describe "GET /api/v1/gateway/health" do
    test "returns health check results", %{conn: conn} do
      conn = get(conn, "/api/v1/gateway/health")
      # May return 200 (ok) or 503 (degraded) depending on environment
      assert conn.status in [200, 503]
      body = Jason.decode!(conn.resp_body)
      assert body["status"] in ["ok", "degraded"]
      assert is_map(body["checks"])
      assert body["timestamp"]
    end
  end
end
