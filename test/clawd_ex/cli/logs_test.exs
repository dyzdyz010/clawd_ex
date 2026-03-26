defmodule ClawdEx.CLI.LogsTest do
  use ExUnit.Case, async: false

  alias ClawdEx.CLI.Logs

  import ExUnit.CaptureIO

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "clawd_logs_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    original_log_dir = Application.get_env(:clawd_ex, :log_dir)
    Application.put_env(:clawd_ex, :log_dir, tmp_dir)

    log_path = Path.join(tmp_dir, "clawd_ex.log")

    on_exit(fn ->
      File.rm_rf(tmp_dir)

      if original_log_dir do
        Application.put_env(:clawd_ex, :log_dir, original_log_dir)
      else
        Application.delete_env(:clawd_ex, :log_dir)
      end
    end)

    {:ok, log_path: log_path}
  end

  test "shows log entries and filters by level", %{log_path: log_path} do
    write_test_log(log_path, [
      "10:00:00.000 [info] Application started",
      "10:00:01.000 [error] Something went wrong",
      "10:00:02.000 [warning] Warning message"
    ])

    # All entries
    output = capture_io(fn -> Logs.run([], []) end)
    assert output =~ "Application started"
    assert output =~ "Something went wrong"

    # Filter by error
    output = capture_io(fn -> Logs.run([], [level: "error"]) end)
    assert output =~ "Something went wrong"
    refute output =~ "Application started"

    # Filter by warn (normalizes to warning)
    output = capture_io(fn -> Logs.run([], [level: "warn"]) end)
    assert output =~ "Warning message"
    refute output =~ "Application started"
  end

  test "respects --tail option", %{log_path: log_path} do
    lines = for i <- 1..100, do: "10:00:#{String.pad_leading(to_string(i), 2, "0")}.000 [info] Line #{i}"
    write_test_log(log_path, lines)

    output = capture_io(fn -> Logs.run([], [tail: 5]) end)
    assert output =~ "Line 96"
    assert output =~ "Line 100"
    refute output =~ "Line 1\n"
  end

  test "shows error when log file not found" do
    output = capture_io(fn -> Logs.run([], []) end)
    assert output =~ "Log file not found"
  end

  test "shows help with --help" do
    output = capture_io(fn -> Logs.run(["--help"], []) end)
    assert output =~ "Usage:"
    assert output =~ "logs"
  end

  test "get_log_path returns configured or default path" do
    path = Logs.get_log_path()
    assert path =~ "clawd_ex.log"

    Application.delete_env(:clawd_ex, :log_dir)
    path = Logs.get_log_path()
    assert path =~ "clawd_ex.log"
    assert path =~ "logs"
  end

  defp write_test_log(path, lines) do
    File.write!(path, Enum.join(lines, "\n") <> "\n")
  end
end
