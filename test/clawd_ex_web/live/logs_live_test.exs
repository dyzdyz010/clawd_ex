defmodule ClawdExWeb.LogsLiveTest do
  use ClawdExWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  @log_dir "priv/logs"

  setup do
    # Ensure log directory exists and create a test log file
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

    on_exit(fn ->
      File.rm(test_path)
    end)

    %{test_file: test_file}
  end

  describe "mount" do
    test "renders logs page with title", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/logs")

      assert html =~ "Logs"
      assert html =~ "View application logs"
    end

    test "shows initial state with no file selected", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/logs")

      assert html =~ "Select a log file to view"
    end

    test "contains key UI elements", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/logs")

      # Title
      assert html =~ "Logs"
      # Refresh button
      assert html =~ "refresh"
      # Auto refresh toggle
      assert html =~ "Auto: OFF"
      # Level selector
      assert html =~ "Level:"
      # Filter input
      assert html =~ "Filter logs"
      # File list section
      assert html =~ "Log Files"
    end

    test "lists available log files", %{conn: conn, test_file: test_file} do
      {:ok, _view, html} = live(conn, "/logs")

      assert html =~ test_file
    end
  end

  describe "events" do
    test "select_file event loads log content", %{conn: conn, test_file: test_file} do
      {:ok, view, _html} = live(conn, "/logs")

      html = render_click(view, "select_file", %{"file" => test_file})
      assert html =~ "Application started"
      assert html =~ "Connection failed"
    end

    test "set_level event filters by level", %{conn: conn, test_file: test_file} do
      {:ok, view, _html} = live(conn, "/logs?file=#{test_file}")

      html = render_change(view, "set_level", %{"level" => "error"})
      assert html =~ "Connection failed"
      refute html =~ "Application started"
    end

    test "filter event filters logs by text", %{conn: conn, test_file: test_file} do
      {:ok, view, _html} = live(conn, "/logs?file=#{test_file}")

      html = render_change(view, "filter", %{"filter" => "Connection"})
      assert html =~ "Connection failed"
      refute html =~ "Application started"
    end

    test "refresh event does not crash", %{conn: conn, test_file: test_file} do
      {:ok, view, _html} = live(conn, "/logs?file=#{test_file}")

      html = render_click(view, "refresh")
      assert html =~ "Logs"
    end

    test "toggle_auto_refresh event toggles auto refresh", %{conn: conn} do
      {:ok, view, html} = live(conn, "/logs")
      assert html =~ "Auto: OFF"

      html = render_click(view, "toggle_auto_refresh")
      assert html =~ "Auto: ON"

      html = render_click(view, "toggle_auto_refresh")
      assert html =~ "Auto: OFF"
    end

    test "clear_logs event clears the selected log file", %{conn: conn, test_file: test_file} do
      {:ok, view, _html} = live(conn, "/logs?file=#{test_file}")

      # Should have content initially
      html = render(view)
      assert html =~ "Application started"

      # Clear logs — after clearing, log content is gone
      html = render_click(view, "clear_logs")
      refute html =~ "Application started"
      refute html =~ "Connection failed"
    end

    test "select_file with nonexistent file shows empty", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/logs")

      # Selecting a file triggers push_patch, so we use navigate
      html = render_click(view, "select_file", %{"file" => "nonexistent.log"})
      # Should show empty state since file doesn't exist
      assert html =~ "No log entries found"
    end

    test "set_level to all shows all levels", %{conn: conn, test_file: test_file} do
      {:ok, view, _html} = live(conn, "/logs?file=#{test_file}")

      # First filter to error
      render_change(view, "set_level", %{"level" => "error"})
      # Then set to all
      html = render_change(view, "set_level", %{"level" => "all"})
      assert html =~ "Application started"
      assert html =~ "Connection failed"
    end
  end
end
