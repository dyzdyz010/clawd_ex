defmodule ClawdExWeb.PluginsLiveTest do
  use ClawdExWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  describe "mount" do
    test "renders plugins page", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/plugins")

      assert html =~ "Plugins"
    end

    test "displays stat cards", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/plugins")

      assert html =~ "Total Plugins"
      assert html =~ "Loaded"
      assert html =~ "Disabled"
      assert html =~ "Errors"
    end

    test "shows MCP Servers section", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/plugins")

      assert html =~ "MCP Servers"
    end

    test "shows auto-refresh note", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/plugins")

      assert html =~ "Auto-refreshes every 10s"
    end
  end

  describe "toggle_plugin event" do
    test "toggle_plugin does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/plugins")

      # Toggling a non-existent plugin should not crash
      html =
        view
        |> render_click("toggle_plugin", %{"id" => "nonexistent-plugin"})

      assert html =~ "Plugins"
    end
  end
end
