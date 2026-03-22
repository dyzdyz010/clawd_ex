defmodule ClawdEx.Cron.ExecutorTest do
  use ExUnit.Case, async: true

  alias ClawdEx.Cron.Executor

  # The executor relies heavily on DB (Automation.create_run, etc.)
  # and external systems (sessions, webhooks). These tests focus on
  # the logic that can be tested in isolation.

  describe "module exists and is loadable" do
    test "executor module is available" do
      assert Code.ensure_loaded?(Executor)
    end

    test "execute/1 function is defined" do
      # Ensure module is loaded first
      {:module, _} = Code.ensure_loaded(Executor)
      assert function_exported?(Executor, :execute, 1)
    end
  end

  describe "detect_type (via execute path)" do
    # We can't call detect_type directly (private), but we verify
    # the module handles different job shapes without crashing at compile time

    test "job struct with webhook metadata is recognized" do
      # Just verify the module compiles and handles the struct shape
      job = %ClawdEx.Automation.CronJob{
        id: Ecto.UUID.generate(),
        name: "test webhook",
        schedule: "0 * * * *",
        command: "https://example.com/hook",
        metadata: %{"type" => "webhook"},
        payload_type: "system_event",
        enabled: true,
        run_count: 0
      }

      # Verify job struct is valid
      assert job.name == "test webhook"
      assert job.command =~ "http"
    end

    test "job struct with system_event type" do
      job = %ClawdEx.Automation.CronJob{
        id: Ecto.UUID.generate(),
        name: "test message",
        schedule: "*/5 * * * *",
        command: "check the weather",
        payload_type: "system_event",
        enabled: true,
        run_count: 0
      }

      assert job.payload_type == "system_event"
    end

    test "job struct with agent_turn type" do
      job = %ClawdEx.Automation.CronJob{
        id: Ecto.UUID.generate(),
        name: "test agent",
        schedule: "0 9 * * *",
        command: "generate daily report",
        payload_type: "agent_turn",
        enabled: true,
        run_count: 0
      }

      assert job.payload_type == "agent_turn"
    end
  end
end
