defmodule ClawdExWeb.Plugs.WebAuthPlugTest do
  use ClawdExWeb.ConnCase, async: false

  alias ClawdExWeb.Plugs.WebAuthPlug

  setup do
    original = Application.get_env(:clawd_ex, :web_auth)
    on_exit(fn -> Application.put_env(:clawd_ex, :web_auth, original || []) end)
    :ok
  end

  describe "when auth is disabled (no token configured)" do
    setup do
      Application.put_env(:clawd_ex, :web_auth, mode: :token, token: nil)
      :ok
    end

    test "passes through without any auth", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{})
        |> WebAuthPlug.call(WebAuthPlug.init([]))

      refute conn.halted
    end

    test "sets web_authenticated in session", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{})
        |> WebAuthPlug.call(WebAuthPlug.init([]))

      assert get_session(conn, :web_authenticated) == true
    end
  end

  describe "when token auth is enabled" do
    setup do
      Application.put_env(:clawd_ex, :web_auth, mode: :token, token: "valid-web-token")
      :ok
    end

    test "redirects to login when no token provided", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{})
        |> Map.put(:params, %{})
        |> WebAuthPlug.call(WebAuthPlug.init([]))

      assert conn.halted
      assert redirected_to(conn) == "/login"
    end

    test "allows access with valid token in URL params", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{})
        |> Map.put(:params, %{"token" => "valid-web-token"})
        |> WebAuthPlug.call(WebAuthPlug.init([]))

      refute conn.halted
      assert get_session(conn, :web_authenticated) == true
    end

    test "returns 401 with invalid token in URL params", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{})
        |> Map.put(:params, %{"token" => "wrong-token"})
        |> WebAuthPlug.call(WebAuthPlug.init([]))

      assert conn.halted
      assert conn.status == 401
    end

    test "allows access with valid Bearer token in header", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{})
        |> Map.put(:params, %{})
        |> put_req_header("authorization", "Bearer valid-web-token")
        |> WebAuthPlug.call(WebAuthPlug.init([]))

      refute conn.halted
      assert get_session(conn, :web_authenticated) == true
    end

    test "allows access when session is already authenticated", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{web_authenticated: true})
        |> Map.put(:params, %{})
        |> WebAuthPlug.call(WebAuthPlug.init([]))

      refute conn.halted
    end

    test "stores return_to path on redirect", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{})
        |> Map.put(:params, %{})
        |> Map.put(:request_path, "/chat")
        |> Map.put(:query_string, "")
        |> WebAuthPlug.call(WebAuthPlug.init([]))

      assert conn.halted
      assert get_session(conn, :return_to) == "/chat"
    end

    test "stores return_to with query string", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{})
        |> Map.put(:params, %{})
        |> Map.put(:request_path, "/chat")
        |> Map.put(:query_string, "agent_id=1")
        |> WebAuthPlug.call(WebAuthPlug.init([]))

      assert conn.halted
      assert get_session(conn, :return_to) == "/chat?agent_id=1"
    end
  end
end
