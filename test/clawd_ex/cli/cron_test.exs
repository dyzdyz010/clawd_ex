defmodule ClawdEx.CLI.CronTest do
  use ClawdEx.DataCase, async: false

  alias ClawdEx.CLI.Cron
  alias ClawdEx.Automation

  import ExUnit.CaptureIO

  test "cron list shows jobs with status" do
    output = capture_io(fn -> Cron.run(["list"], []) end)
    assert output =~ "No cron jobs found."

    {:ok, _} = Automation.create_job(%{name: "enabled-job-#{System.unique_integer()}", schedule: "*/5 * * * *", command: "echo on", enabled: true})
    {:ok, _} = Automation.create_job(%{name: "disabled-job-#{System.unique_integer()}", schedule: "0 0 * * *", command: "echo off", enabled: false})

    output = capture_io(fn -> Cron.run(["list"], []) end)
    assert output =~ "Cron Jobs"
    assert output =~ "*/5 * * * *"
    assert output =~ "✓"
    assert output =~ "✗"
    assert output =~ "Total:"
  end

  test "cron run shows error for missing/nonexistent job" do
    output = capture_io(fn -> Cron.run(["run"], []) end)
    assert output =~ "job ID is required"

    output = capture_io(fn -> Cron.run(["run", Ecto.UUID.generate()], []) end)
    assert output =~ "Cron job not found"
  end

  test "shows help with no args or --help" do
    for args <- [[], ["--help"]] do
      output = capture_io(fn -> Cron.run(args, []) end)
      assert output =~ "Usage:"
    end
  end

  test "shows error for unknown subcommand" do
    output = capture_io(fn -> Cron.run(["unknown"], []) end)
    assert output =~ "Unknown cron subcommand"
  end
end
