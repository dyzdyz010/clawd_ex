defmodule ClawdExWeb.Plugs.AuthTest do
  use ClawdExWeb.ConnCase, async: true

  alias ClawdExWeb.Plugs.Auth

  describe "when auth is disabled" do
    setup do
      original = Application.get_env(:clawd_ex, :auth)
      Application.put_env(:clawd_ex, :auth, tokens: [], enabled: false)
      on_exit(fn -> Application.put_env(:clawd_ex, :auth, original || []) end)
      :ok
    end

    test "passes through without token", %{conn: conn} do
      conn =
        conn
        |> Auth.call(Auth.init([]))

      refute conn.halted
    end

    test "passes through with invalid token", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer wrong-token")
        |> Auth.call(Auth.init([]))

      refute conn.halted
    end
  end

  describe "when auth is enabled" do
    setup do
      original = Application.get_env(:clawd_ex, :auth)
      Application.put_env(:clawd_ex, :auth, tokens: ["valid-token-123"], enabled: true)
      on_exit(fn -> Application.put_env(:clawd_ex, :auth, original || []) end)
      :ok
    end

    test "allows request with valid Bearer token", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer valid-token-123")
        |> Auth.call(Auth.init([]))

      refute conn.halted
      assert conn.assigns[:authenticated] == true
    end

    test "rejects request without Authorization header", %{conn: conn} do
      conn = Auth.call(conn, Auth.init([]))

      assert conn.halted
      assert conn.status == 401

      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "unauthorized"
    end

    test "rejects request with invalid token", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer wrong-token")
        |> Auth.call(Auth.init([]))

      assert conn.halted
      assert conn.status == 401
    end

    test "rejects request with non-Bearer auth", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Basic dXNlcjpwYXNz")
        |> Auth.call(Auth.init([]))

      assert conn.halted
      assert conn.status == 401
    end

    test "rejects request with empty Bearer token", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer ")
        |> Auth.call(Auth.init([]))

      assert conn.halted
      assert conn.status == 401
    end

    test "supports multiple valid tokens", %{conn: conn} do
      Application.put_env(:clawd_ex, :auth,
        tokens: ["token-a", "token-b", "token-c"],
        enabled: true
      )

      conn_a =
        build_conn()
        |> put_req_header("authorization", "Bearer token-a")
        |> Auth.call(Auth.init([]))

      refute conn_a.halted

      conn_b =
        build_conn()
        |> put_req_header("authorization", "Bearer token-b")
        |> Auth.call(Auth.init([]))

      refute conn_b.halted

      conn_bad =
        build_conn()
        |> put_req_header("authorization", "Bearer token-d")
        |> Auth.call(Auth.init([]))

      assert conn_bad.halted
    end
  end

  describe "when auth is enabled but tokens list is empty" do
    setup do
      original = Application.get_env(:clawd_ex, :auth)
      Application.put_env(:clawd_ex, :auth, tokens: [], enabled: true)
      on_exit(fn -> Application.put_env(:clawd_ex, :auth, original || []) end)
      :ok
    end

    test "passes through (no tokens = disabled)", %{conn: conn} do
      conn = Auth.call(conn, Auth.init([]))
      refute conn.halted
    end
  end

  describe "when tokens contain nil values" do
    setup do
      original = Application.get_env(:clawd_ex, :auth)
      Application.put_env(:clawd_ex, :auth, tokens: [nil, "valid-token"], enabled: true)
      on_exit(fn -> Application.put_env(:clawd_ex, :auth, original || []) end)
      :ok
    end

    test "filters out nil tokens and still authenticates", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer valid-token")
        |> Auth.call(Auth.init([]))

      refute conn.halted
    end
  end
end
