defmodule ClawdExWeb.LoginLiveTest do
  # Must be async: false because we modify global Application env
  use ClawdExWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  setup do
    # Store and restore original config around each test
    original = Application.get_env(:clawd_ex, :web_auth)
    on_exit(fn -> Application.put_env(:clawd_ex, :web_auth, original) end)
    :ok
  end

  describe "unauthenticated access" do
    test "shows login form when auth is enabled (token mode)", %{conn: conn} do
      Application.put_env(:clawd_ex, :web_auth, mode: :token, token: "test-secret-token")

      {:ok, _view, html} = live(conn, "/login")

      assert html =~ "Authentication required"
      assert html =~ "Access Token"
      assert html =~ "Login"
    end

    test "shows password form when auth mode is password", %{conn: conn} do
      Application.put_env(:clawd_ex, :web_auth, mode: :password, username: "admin", password: "secret")

      {:ok, _view, html} = live(conn, "/login")

      assert html =~ "Authentication required"
      assert html =~ "Username"
      assert html =~ "Password"
    end
  end

  describe "auth disabled" do
    test "redirects to / when auth is disabled", %{conn: conn} do
      Application.put_env(:clawd_ex, :web_auth, mode: :disabled)

      # Auth disabled → mount does push_navigate to /
      assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, "/login")
    end
  end

  describe "token login" do
    test "shows error for invalid token", %{conn: conn} do
      Application.put_env(:clawd_ex, :web_auth, mode: :token, token: "correct-token")

      {:ok, view, _html} = live(conn, "/login")

      html =
        view
        |> render_submit("login_token", %{"token" => "wrong-token"})

      assert html =~ "Invalid token"
    end

    test "redirects on valid token submission", %{conn: conn} do
      Application.put_env(:clawd_ex, :web_auth, mode: :token, token: "correct-token")

      {:ok, view, _html} = live(conn, "/login")

      # Valid token triggers a non-live redirect to /auth/callback
      render_submit(view, "login_token", %{"token" => "correct-token"})
      flash = assert_redirect(view, "/auth/callback?token=correct-token")
      assert flash == %{}
    end
  end
end
