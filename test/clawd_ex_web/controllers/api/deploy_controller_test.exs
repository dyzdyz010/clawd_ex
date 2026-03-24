defmodule ClawdExWeb.Api.DeployControllerTest do
  use ClawdExWeb.ConnCase

  describe "GET /api/v1/deploy/status" do
    test "returns deploy status", %{conn: conn} do
      conn = get(conn, "/api/v1/deploy/status")
      body = json_response(conn, 200)

      assert is_binary(body["version"])
      assert is_binary(body["git_sha"])
      assert is_binary(body["started_at"])
      assert is_integer(body["uptime_seconds"])
      assert is_binary(body["environment"])
    end
  end

  describe "GET /api/v1/deploy/history" do
    test "returns deploy history", %{conn: conn} do
      conn = get(conn, "/api/v1/deploy/history")
      body = json_response(conn, 200)

      assert is_list(body["deploys"])
      assert is_integer(body["total"])
    end
  end

  describe "POST /api/v1/deploy/trigger" do
    test "triggers deployment", %{conn: conn} do
      conn = post(conn, "/api/v1/deploy/trigger")
      body = json_response(conn, 202)

      assert body["status"] == "triggered"
      assert is_binary(body["deploy_id"])
      assert is_binary(body["started_at"])

      # Wait for async deploy to complete
      Process.sleep(2_000)
    end
  end

  describe "POST /api/v1/deploy/rollback" do
    test "triggers rollback", %{conn: conn} do
      conn = post(conn, "/api/v1/deploy/rollback")
      body = json_response(conn, 202)

      assert body["status"] == "triggered"
      assert is_binary(body["deploy_id"])

      # Wait for async deploy to complete
      Process.sleep(2_000)
    end
  end
end
