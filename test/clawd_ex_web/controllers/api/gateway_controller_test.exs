defmodule ClawdExWeb.Api.GatewayControllerTest do
  use ClawdExWeb.ConnCase

  test "GET /api/v1/gateway/status returns full status", %{conn: conn} do
    conn = get(conn, "/api/v1/gateway/status")
    body = json_response(conn, 200)

    assert %{"version" => _, "uptime_seconds" => _, "sessions" => _, "agents" => _} = body
    assert %{"total" => _, "connected" => _, "pending" => _} = body["nodes"]
    assert %{"active" => _, "total" => _} = body["sessions"]
    assert %{"total" => _, "active" => _} = body["agents"]
  end

  test "GET /api/v1/gateway/health returns health check", %{conn: conn} do
    conn = get(conn, "/api/v1/gateway/health")
    assert conn.status in [200, 503]
    body = Jason.decode!(conn.resp_body)
    assert body["status"] in ["ok", "degraded"]
    assert is_map(body["checks"])
    assert body["timestamp"]
  end
end
