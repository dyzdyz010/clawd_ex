defmodule ClawdExWeb.GatewayLiveTest do
  use ClawdExWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  test "renders gateway page with key sections", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/gateway")

    assert html =~ "Gateway"
    assert html =~ "Status"
    assert html =~ "Running"
    assert html =~ "Listen"
    assert html =~ "Connections"
    assert html =~ "WS:"
    assert html =~ "HTTP:"
    assert html =~ "Uptime"
    assert html =~ "Memory Usage"
    assert html =~ "Total"
    assert html =~ "Processes"
    assert html =~ "ETS"
    assert html =~ "Atoms"
    assert html =~ "Binary"
    assert html =~ "BEAM VM Info"
    assert html =~ "Schedulers"
    assert html =~ "Process Count"
    assert html =~ "OTP Release"
    assert html =~ "Restart"
  end

  test "restart shows flash message", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/gateway")

    html = view |> element("button", "Restart") |> render_click()

    assert html =~ "Restart scheduled" or html =~ "Restarting"
  end

  test "updates on tick", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/gateway")

    send(view.pid, :tick)

    html = render(view)
    assert html =~ "Gateway"
    assert html =~ "Memory Usage"
  end
end
