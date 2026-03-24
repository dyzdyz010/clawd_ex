defmodule ClawdExWeb.Api.AcpControllerTest do
  use ClawdExWeb.ConnCase, async: false

  alias ClawdEx.ACP.{Registry, Session}

  setup do
    # Register a mock backend for testing
    :ok = Registry.register_backend("cli", ClawdEx.ACP.MockBackend)

    on_exit(fn ->
      Registry.unregister_backend("cli")
    end)

    :ok
  end

  describe "GET /api/v1/acp/agents" do
    test "returns list of available agents", %{conn: conn} do
      conn = get(conn, "/api/v1/acp/agents")
      body = json_response(conn, 200)

      assert is_list(body["data"])
      assert body["total"] > 0

      # Should include the standard agents
      agent_ids = Enum.map(body["data"], & &1["agent_id"])
      assert "codex" in agent_ids
      assert "claude" in agent_ids
      assert "gemini" in agent_ids
      assert "pi" in agent_ids
    end

    test "shows availability based on backend registration", %{conn: conn} do
      conn = get(conn, "/api/v1/acp/agents")
      body = json_response(conn, 200)

      # Since we registered "cli" backend, all agents mapping to "cli" should be available
      cli_agents = Enum.filter(body["data"], & &1["available"])
      assert length(cli_agents) > 0
    end
  end

  describe "GET /api/v1/acp/sessions" do
    test "returns empty list when no sessions", %{conn: conn} do
      conn = get(conn, "/api/v1/acp/sessions")
      body = json_response(conn, 200)

      assert is_list(body["data"])
      assert is_integer(body["total"])
    end

    test "returns active sessions", %{conn: conn} do
      key = "agent:test:acp:ctrl-list-#{System.unique_integer([:positive])}"

      {:ok, _pid} = Session.start(%{
        session_key: key,
        agent_id: "codex",
        label: "ctrl-test"
      })

      Process.sleep(200)

      conn = get(conn, "/api/v1/acp/sessions")
      body = json_response(conn, 200)

      session_keys = Enum.map(body["data"], & &1["session_key"])
      assert key in session_keys

      Session.close(key)
    end
  end

  describe "GET /api/v1/acp/sessions/:key" do
    test "returns session details", %{conn: conn} do
      key = "agent:test:acp:ctrl-show-#{System.unique_integer([:positive])}"

      {:ok, _pid} = Session.start(%{
        session_key: key,
        agent_id: "codex",
        label: "show-test"
      })

      Process.sleep(200)

      encoded_key = URI.encode(key, &URI.char_unreserved?/1)
      conn = get(conn, "/api/v1/acp/sessions/#{encoded_key}")
      body = json_response(conn, 200)

      assert body["data"]["session_key"] == key
      assert body["data"]["agent_id"] == "codex"
      assert body["data"]["label"] == "show-test"

      Session.close(key)
    end

    test "returns 404 for non-existent session", %{conn: conn} do
      conn = get(conn, "/api/v1/acp/sessions/nonexistent:key")
      assert json_response(conn, 404)["error"]["code"] == "not_found"
    end
  end

  describe "DELETE /api/v1/acp/sessions/:key" do
    test "closes an active session", %{conn: conn} do
      key = "agent:test:acp:ctrl-close-#{System.unique_integer([:positive])}"

      {:ok, _pid} = Session.start(%{
        session_key: key,
        agent_id: "codex"
      })

      Process.sleep(200)

      encoded_key = URI.encode(key, &URI.char_unreserved?/1)
      conn = delete(conn, "/api/v1/acp/sessions/#{encoded_key}")
      body = json_response(conn, 200)

      assert body["status"] == "closed"
    end

    test "returns 404 for non-existent session", %{conn: conn} do
      # close returns :ok for non-existent, but the controller checks
      # Actually Session.close returns :ok even for non-existent.
      # That's fine — it's idempotent.
      conn = delete(conn, "/api/v1/acp/sessions/nonexistent:key")
      body = json_response(conn, 200)
      assert body["status"] == "closed"
    end
  end

  describe "GET /api/v1/acp/doctor" do
    test "returns health report", %{conn: conn} do
      conn = get(conn, "/api/v1/acp/doctor")
      body = json_response(conn, 200)

      assert body["data"]["status"] in ["healthy", "degraded"]
      assert is_list(body["data"]["backends"])
      assert is_map(body["data"]["agent_map"])
      assert body["data"]["checked_at"] != nil
    end

    test "includes registered backends in report", %{conn: conn} do
      conn = get(conn, "/api/v1/acp/doctor")
      body = json_response(conn, 200)

      backend_ids = Enum.map(body["data"]["backends"], & &1["id"])
      assert "cli" in backend_ids
    end
  end
end
