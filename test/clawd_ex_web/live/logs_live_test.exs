defmodule ClawdExWeb.LogsLiveTest do
  use ClawdExWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  @log_dir "priv/logs"

  setup do
    File.mkdir_p!(@log_dir)
    test_file = "test_#{System.unique_integer([:positive])}.log"
    test_path = Path.join(@log_dir, test_file)

    log_content = """
    [INFO] 2024-01-01 10:00:00 Application started
    [DEBUG] 2024-01-01 10:00:01 Loading config
    [WARN] 2024-01-01 10:00:02 Deprecated function used
    [ERROR] 2024-01-01 10:00:03 Connection failed
    [INFO] 2024-01-01 10:00:04 Request completed
    """

    File.write!(test_path, log_content)
    on_exit(fn -> File.rm(test_path) end)

    %{test_file: test_file}
  end

  test "renders logs page with key elements", %{conn: conn, test_file: test_file} do
    {:ok, _view, html} = live(conn, "/logs")

    assert html =~ "Logs"
    assert html =~ "View application logs"
    assert html =~ "Select a log file to view"
    assert html =~ "refresh"
    assert html =~ "Auto: OFF"
    assert html =~ "Level:"
    assert html =~ "Filter logs"
    assert html =~ "Log Files"
    assert html =~ test_file
  end

  test "select_file loads log content", %{conn: conn, test_file: test_file} do
    {:ok, view, _html} = live(conn, "/logs")

    html = render_click(view, "select_file", %{"file" => test_file})
    assert html =~ "Application started"
    assert html =~ "Connection failed"
  end

  test "level and text filtering", %{conn: conn, test_file: test_file} do
    {:ok, view, _html} = live(conn, "/logs?file=#{test_file}")

    # Filter by error level
    html = render_change(view, "set_level", %{"level" => "error"})
    assert html =~ "Connection failed"
    refute html =~ "Application started"

    # Reset to all
    html = render_change(view, "set_level", %{"level" => "all"})
    assert html =~ "Application started"
    assert html =~ "Connection failed"

    # Filter by text
    html = render_change(view, "filter", %{"filter" => "Connection"})
    assert html =~ "Connection failed"
    refute html =~ "Application started"
  end

  test "toggle_auto_refresh toggles state", %{conn: conn} do
    {:ok, view, html} = live(conn, "/logs")
    assert html =~ "Auto: OFF"

    html = render_click(view, "toggle_auto_refresh")
    assert html =~ "Auto: ON"

    html = render_click(view, "toggle_auto_refresh")
    assert html =~ "Auto: OFF"
  end

  test "clear_logs clears the log file", %{conn: conn, test_file: test_file} do
    {:ok, view, _html} = live(conn, "/logs?file=#{test_file}")

    html = render(view)
    assert html =~ "Application started"

    html = render_click(view, "clear_logs")
    refute html =~ "Application started"
    refute html =~ "Connection failed"
  end

  test "select nonexistent file shows empty state", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/logs")

    html = render_click(view, "select_file", %{"file" => "nonexistent.log"})
    assert html =~ "No log entries found"
  end
end
