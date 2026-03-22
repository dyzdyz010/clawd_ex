defmodule ClawdExWeb.AuthControllerTest do
  use ClawdExWeb.ConnCase, async: false

  setup do
    original = Application.get_env(:clawd_ex, :web_auth)
    on_exit(fn -> Application.put_env(:clawd_ex, :web_auth, original || []) end)
    :ok
  end

  describe "callback with token" do
    setup do
      Application.put_env(:clawd_ex, :web_auth, mode: :token, token: "test-token")
      :ok
    end

    test "sets session and redirects to / with valid token", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{})
        |> get("/auth/callback?token=test-token")

      assert redirected_to(conn) == "/"
      assert get_session(conn, :web_authenticated) == true
    end

    test "redirects to return_to path after login", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{return_to: "/chat"})
        |> get("/auth/callback?token=test-token")

      assert redirected_to(conn) == "/chat"
    end

    test "redirects to login with invalid token", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{})
        |> get("/auth/callback?token=wrong-token")

      assert redirected_to(conn) == "/login"
    end
  end

  describe "callback with password" do
    setup do
      Application.put_env(:clawd_ex, :web_auth, mode: :password, username: "admin", password: "secret")
      :ok
    end

    test "sets session with _auth=password param", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{})
        |> get("/auth/callback?_auth=password")

      assert redirected_to(conn) == "/"
      assert get_session(conn, :web_authenticated) == true
    end
  end

  describe "logout" do
    test "clears session and redirects to login", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{web_authenticated: true})
        |> get("/auth/logout")

      assert redirected_to(conn) == "/login"
      refute get_session(conn, :web_authenticated)
    end
  end
end
