defmodule ClawdExWeb.Plugs.ApiAuthPlugTest do
  use ClawdExWeb.ConnCase

  alias ClawdExWeb.Plugs.ApiAuthPlug

  describe "when no token is configured (dev mode)" do
    test "allows all requests through", %{conn: conn} do
      # Clear any configured tokens
      original_api = Application.get_env(:clawd_ex, :api_token)
      original_gw = Application.get_env(:clawd_ex, :gateway_token)

      Application.put_env(:clawd_ex, :api_token, nil)
      Application.put_env(:clawd_ex, :gateway_token, nil)

      try do
        conn = ApiAuthPlug.call(conn, [])
        refute conn.halted
      after
        Application.put_env(:clawd_ex, :api_token, original_api)
        Application.put_env(:clawd_ex, :gateway_token, original_gw)
      end
    end
  end

  describe "when token is configured" do
    setup do
      original = Application.get_env(:clawd_ex, :api_token)
      Application.put_env(:clawd_ex, :api_token, "test-secret-token")

      on_exit(fn ->
        Application.put_env(:clawd_ex, :api_token, original)
      end)

      :ok
    end

    test "allows request with valid Bearer token", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer test-secret-token")
        |> ApiAuthPlug.call([])

      refute conn.halted
    end

    test "rejects request with invalid Bearer token", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer wrong-token")
        |> ApiAuthPlug.call([])

      assert conn.halted
      assert conn.status == 401
    end

    test "rejects request with no authorization header", %{conn: conn} do
      conn = ApiAuthPlug.call(conn, [])

      assert conn.halted
      assert conn.status == 401
    end

    test "rejects request with non-Bearer auth", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Basic dXNlcjpwYXNz")
        |> ApiAuthPlug.call([])

      assert conn.halted
      assert conn.status == 401
    end
  end
end
