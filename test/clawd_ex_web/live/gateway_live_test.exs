defmodule ClawdExWeb.GatewayLiveTest do
  use ClawdExWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  describe "mount" do
    test "renders gateway page", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/gateway")

      assert html =~ "Gateway"
    end

    test "displays endpoint status", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/gateway")

      # Should show running status since we're testing with a running endpoint
      assert html =~ "Status"
      assert html =~ "Running"
    end

    test "displays listen address", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/gateway")

      assert html =~ "Listen"
    end

    test "displays connection counts", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/gateway")

      assert html =~ "Connections"
      assert html =~ "WS:"
      assert html =~ "HTTP:"
    end

    test "displays uptime", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/gateway")

      assert html =~ "Uptime"
    end

    test "displays memory usage section", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/gateway")

      assert html =~ "Memory Usage"
      assert html =~ "Total"
      assert html =~ "Processes"
      assert html =~ "ETS"
      assert html =~ "Atoms"
      assert html =~ "Binary"
    end

    test "displays BEAM VM info", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/gateway")

      assert html =~ "BEAM VM Info"
      assert html =~ "Schedulers"
      assert html =~ "Process Count"
      assert html =~ "OTP Release"
    end

    test "displays restart button", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/gateway")

      assert html =~ "Restart"
    end
  end

  describe "events" do
    test "restart shows flash message", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/gateway")

      html = view |> element("button", "Restart") |> render_click()

      assert html =~ "Restart scheduled" or html =~ "Restarting"
    end
  end

  describe "auto-refresh" do
    test "updates on tick", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/gateway")

      # Simulate a tick
      send(view.pid, :tick)

      # Should still render without errors
      html = render(view)
      assert html =~ "Gateway"
      assert html =~ "Memory Usage"
    end
  end
end
