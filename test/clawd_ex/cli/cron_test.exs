defmodule ClawdEx.CLI.CronTest do
  use ClawdEx.DataCase, async: false

  alias ClawdEx.CLI.Cron
  alias ClawdEx.Automation
  alias ClawdEx.Automation.CronJob

  import ExUnit.CaptureIO

  describe "cron list" do
    test "shows empty message when no cron jobs" do
      output = capture_io(fn -> Cron.run(["list"], []) end)
      assert output =~ "No cron jobs found."
    end

    test "lists cron jobs from database" do
      {:ok, _job} =
        Automation.create_job(%{
          name: "test-job-#{System.unique_integer()}",
          schedule: "*/5 * * * *",
          command: "echo hello"
        })

      output = capture_io(fn -> Cron.run(["list"], []) end)
      assert output =~ "Cron Jobs"
      assert output =~ "test-job-"
      assert output =~ "*/5 * * * *"
      assert output =~ "Total:"
    end

    test "shows enabled/disabled status" do
      {:ok, _enabled} =
        Automation.create_job(%{
          name: "enabled-job-#{System.unique_integer()}",
          schedule: "0 * * * *",
          command: "echo on",
          enabled: true
        })

      {:ok, _disabled} =
        Automation.create_job(%{
          name: "disabled-job-#{System.unique_integer()}",
          schedule: "0 0 * * *",
          command: "echo off",
          enabled: false
        })

      output = capture_io(fn -> Cron.run(["list"], []) end)
      assert output =~ "✓"
      assert output =~ "✗"
    end

    test "shows help with --help flag" do
      output = capture_io(fn -> Cron.run(["list"], [help: true]) end)
      assert output =~ "Usage:"
      assert output =~ "cron list"
    end
  end

  describe "cron run" do
    test "shows error when job not found" do
      fake_id = Ecto.UUID.generate()
      output = capture_io(fn -> Cron.run(["run", fake_id], []) end)
      assert output =~ "Cron job not found"
    end

    test "shows error when id missing" do
      output = capture_io(fn -> Cron.run(["run"], []) end)
      assert output =~ "job ID is required"
    end

    test "shows help with --help flag" do
      output = capture_io(fn -> Cron.run(["run", "x"], [help: true]) end)
      assert output =~ "Usage:"
      assert output =~ "cron run"
    end
  end

  describe "cron help" do
    test "shows help with no args" do
      output = capture_io(fn -> Cron.run([], []) end)
      assert output =~ "Usage:"
      assert output =~ "list"
      assert output =~ "run"
    end

    test "shows help with --help flag" do
      output = capture_io(fn -> Cron.run(["--help"], []) end)
      assert output =~ "Usage:"
    end

    test "shows error for unknown subcommand" do
      output = capture_io(fn -> Cron.run(["unknown"], []) end)
      assert output =~ "Unknown cron subcommand"
    end
  end
end
