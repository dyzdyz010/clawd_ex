defmodule ClawdExWeb.SettingsLiveTest do
  use ClawdExWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  describe "mount" do
    test "renders settings page", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/settings")

      assert html =~ "Settings"
    end

    test "displays page subtitle", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/settings")

      assert html =~ "Application configuration and system info"
    end

    test "shows tab navigation", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/settings")

      assert html =~ "General"
      assert html =~ "AI Providers"
      assert html =~ "Environment"
      assert html =~ "Skills"
      assert html =~ "System Info"
    end

    test "shows general tab by default", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/settings")

      assert html =~ "General Configuration"
    end

    test "displays restart button", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/settings")

      assert html =~ "Restart Application"
    end
  end

  describe "events" do
    test "switch_tab to ai does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings")

      view
      |> render_click("switch_tab", %{"tab" => "ai"})

      html = render(view)
      assert html =~ "AI Providers"
    end

    test "switch_tab to env does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings")

      view
      |> render_click("switch_tab", %{"tab" => "env"})

      html = render(view)
      assert html =~ "Environment Variables"
    end

    test "switch_tab to skills does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings")

      view
      |> render_click("switch_tab", %{"tab" => "skills"})

      html = render(view)
      assert html =~ "Skills Configuration"
    end

    test "switch_tab to system does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings")

      view
      |> render_click("switch_tab", %{"tab" => "system"})

      html = render(view)
      assert html =~ "System Information"
    end

    test "switch_tab back to general does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings")

      view |> render_click("switch_tab", %{"tab" => "ai"})
      view |> render_click("switch_tab", %{"tab" => "general"})

      html = render(view)
      assert html =~ "General Configuration"
    end

    test "general tab shows application info", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/settings")

      assert html =~ "Application Name"
      assert html =~ "Environment"
      assert html =~ "HTTP Port"
    end

    test "system tab shows system info", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings")

      view
      |> render_click("switch_tab", %{"tab" => "system"})

      html = render(view)
      assert html =~ "Elixir Version"
      assert html =~ "OTP Version"
      assert html =~ "Total Memory"
      assert html =~ "Process Count"
      assert html =~ "Uptime"
    end

    test "ai tab shows provider status", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings")

      view
      |> render_click("switch_tab", %{"tab" => "ai"})

      html = render(view)
      assert html =~ "Anthropic Claude"
      assert html =~ "OpenAI"
      assert html =~ "Google Gemini"
    end
  end
end
