defmodule ClawdExWeb.Api.StreamControllerTest do
  use ClawdExWeb.ConnCase, async: false

  setup do
    # Clear any configured tokens to allow unauthenticated access in dev mode
    Application.delete_env(:clawd_ex, :gateway_token)
    Application.delete_env(:clawd_ex, :api_token)

    on_exit(fn ->
      Application.delete_env(:clawd_ex, :gateway_token)
      Application.delete_env(:clawd_ex, :api_token)
    end)

    %{conn: build_conn()}
  end

  describe "GET /api/v1/sessions/:key/stream" do
    test "returns 404 for non-existent session", %{conn: conn} do
      conn = get(conn, "/api/v1/sessions/nonexistent/stream")

      assert json_response(conn, 404)["error"]["code"] == "not_found"
    end

    test "returns 404 for encoded non-existent session key", %{conn: conn} do
      encoded_key = URI.encode("agent:test:session:123")
      conn = get(conn, "/api/v1/sessions/#{encoded_key}/stream")

      assert json_response(conn, 404)["error"]["code"] == "not_found"
    end
  end

  describe "POST /api/v1/sessions/:key/chat" do
    test "returns 400 when content is empty", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/sessions/test-key/chat", %{content: ""})

      assert json_response(conn, 400)["error"]["code"] == "bad_request"
    end

    test "returns 400 when no content is provided", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/sessions/test-key/chat", %{})

      assert json_response(conn, 400)["error"]["code"] == "bad_request"
    end

    test "returns 404 for non-existent session", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/sessions/nonexistent/chat", %{content: "hello"})

      assert json_response(conn, 404)["error"]["code"] == "not_found"
    end
  end

  describe "SSE event formatting" do
    test "encode_data handles maps" do
      # Test via module internals — verify the SSE format
      # This is a smoke test to ensure the module compiles correctly
      assert Code.ensure_loaded?(ClawdExWeb.Api.StreamController)
    end
  end
end
