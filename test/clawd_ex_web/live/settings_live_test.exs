defmodule ClawdExWeb.SettingsLiveTest do
  use ClawdExWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  test "renders settings page with key elements", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/settings")

    assert html =~ "Settings"
    assert html =~ "Application configuration and system info"
    assert html =~ "General"
    assert html =~ "AI Providers"
    assert html =~ "Environment"
    assert html =~ "Skills"
    assert html =~ "System Info"
    assert html =~ "General Configuration"
    assert html =~ "Restart Application"
    assert html =~ "Application Name"
    assert html =~ "Environment"
    assert html =~ "HTTP Port"
  end

  test "tab switching shows correct content", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/settings")

    tabs = [
      {"ai", ["AI Providers", "Anthropic Claude", "OpenAI", "Google Gemini"]},
      {"env", ["Environment Variables"]},
      {"skills", ["Skills Configuration"]},
      {"system", ["System Information", "Elixir Version", "OTP Version", "Total Memory", "Process Count", "Uptime"]},
      {"general", ["General Configuration"]}
    ]

    for {tab, assertions} <- tabs do
      html = view |> render_click("switch_tab", %{"tab" => tab})
      for text <- assertions, do: assert html =~ text
    end
  end
end
