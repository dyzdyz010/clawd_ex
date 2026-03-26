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

  test "GET stream returns 404 for non-existent session", %{conn: conn} do
    conn = get(conn, "/api/v1/sessions/nonexistent/stream")
    assert json_response(conn, 404)["error"]["code"] == "not_found"
  end

  test "POST chat returns 400 for missing/empty content", %{conn: conn} do
    conn1 =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/api/v1/sessions/test-key/chat", %{content: ""})

    assert json_response(conn1, 400)["error"]["code"] == "bad_request"

    conn2 =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/v1/sessions/test-key/chat", %{})

    assert json_response(conn2, 400)["error"]["code"] == "bad_request"
  end

  test "POST chat returns 404 for non-existent session", %{conn: conn} do
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/api/v1/sessions/nonexistent/chat", %{content: "hello"})

    assert json_response(conn, 404)["error"]["code"] == "not_found"
  end
end
