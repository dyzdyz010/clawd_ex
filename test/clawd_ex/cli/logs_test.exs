defmodule ClawdEx.CLI.LogsTest do
  use ExUnit.Case, async: true

  alias ClawdEx.CLI.Logs

  import ExUnit.CaptureIO

  @test_log_dir "test/tmp/logs"

  setup do
    File.mkdir_p!(@test_log_dir)
    log_path = Path.join(@test_log_dir, "test_#{System.unique_integer([:positive])}.log")

    on_exit(fn ->
      File.rm(log_path)
    end)

    {:ok, log_path: log_path}
  end

  describe "logs with log file" do
    test "shows log entries", %{log_path: log_path} do
      write_test_log(log_path, [
        "10:00:00.000 [info] Application started",
        "10:00:01.000 [info] Request received",
        "10:00:02.000 [error] Something went wrong"
      ])

      Application.put_env(:clawd_ex, :log_path, log_path)

      output = capture_io(fn -> Logs.run([], []) end)
      assert output =~ "Application started"
      assert output =~ "Request received"
      assert output =~ "Something went wrong"

      Application.delete_env(:clawd_ex, :log_path)
    end

    test "filters by level", %{log_path: log_path} do
      write_test_log(log_path, [
        "10:00:00.000 [info] Info message",
        "10:00:01.000 [error] Error message",
        "10:00:02.000 [warning] Warning message"
      ])

      Application.put_env(:clawd_ex, :log_path, log_path)

      output = capture_io(fn -> Logs.run([], [level: "error"]) end)
      assert output =~ "Error message"
      refute output =~ "Info message"
      refute output =~ "Warning message"

      Application.delete_env(:clawd_ex, :log_path)
    end

    test "filters by warn level (normalizes to warning)", %{log_path: log_path} do
      write_test_log(log_path, [
        "10:00:00.000 [info] Info message",
        "10:00:01.000 [warning] Warning message"
      ])

      Application.put_env(:clawd_ex, :log_path, log_path)

      output = capture_io(fn -> Logs.run([], [level: "warn"]) end)
      assert output =~ "Warning message"
      refute output =~ "Info message"

      Application.delete_env(:clawd_ex, :log_path)
    end

    test "respects --tail option", %{log_path: log_path} do
      lines = for i <- 1..100, do: "10:00:#{String.pad_leading(to_string(i), 2, "0")}.000 [info] Line #{i}"
      write_test_log(log_path, lines)

      Application.put_env(:clawd_ex, :log_path, log_path)

      output = capture_io(fn -> Logs.run([], [tail: 5]) end)
      assert output =~ "Line 96"
      assert output =~ "Line 100"
      refute output =~ "Line 1\n"

      Application.delete_env(:clawd_ex, :log_path)
    end

    test "shows empty message when no entries match", %{log_path: log_path} do
      write_test_log(log_path, [
        "10:00:00.000 [info] Info message"
      ])

      Application.put_env(:clawd_ex, :log_path, log_path)

      output = capture_io(fn -> Logs.run([], [level: "error"]) end)
      assert output =~ "No log entries found"

      Application.delete_env(:clawd_ex, :log_path)
    end
  end

  describe "logs with missing file" do
    test "shows error when log file not found" do
      Application.put_env(:clawd_ex, :log_path, "/tmp/nonexistent_clawd_ex_log.log")

      output = capture_io(fn -> Logs.run([], []) end)
      assert output =~ "Log file not found"

      Application.delete_env(:clawd_ex, :log_path)
    end
  end

  describe "logs help" do
    test "shows help with --help flag" do
      output = capture_io(fn -> Logs.run(["--help"], []) end)
      assert output =~ "Usage:"
      assert output =~ "logs"
    end

    test "shows help with help option" do
      output = capture_io(fn -> Logs.run([], [help: true]) end)
      assert output =~ "Usage:"
    end
  end

  describe "get_log_path/0" do
    test "returns configured path when set" do
      Application.put_env(:clawd_ex, :log_path, "/custom/path.log")
      assert Logs.get_log_path() == "/custom/path.log"
      Application.delete_env(:clawd_ex, :log_path)
    end

    test "returns default path when not configured" do
      Application.delete_env(:clawd_ex, :log_path)
      path = Logs.get_log_path()
      assert path =~ "log/"
      assert path =~ ".log"
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp write_test_log(path, lines) do
    content = Enum.join(lines, "\n") <> "\n"
    File.write!(path, content)
  end
end
