defmodule ClawdExWeb.PluginsLiveTest do
  use ClawdExWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  test "renders plugins page with key elements", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/plugins")

    assert html =~ "Plugins"
    assert html =~ "Total Plugins"
    assert html =~ "Loaded"
    assert html =~ "Disabled"
    assert html =~ "Errors"
    assert html =~ "MCP Servers"
    assert html =~ "Auto-refreshes every 10s"
  end

  test "toggle_plugin does not crash", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/plugins")

    html =
      view
      |> render_click("toggle_plugin", %{"id" => "nonexistent-plugin"})

    assert html =~ "Plugins"
  end
end
