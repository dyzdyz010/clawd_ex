defmodule ClawdEx.CLI.GatewayTest do
  use ClawdEx.DataCase, async: false

  alias ClawdEx.CLI.Gateway

  import ExUnit.CaptureIO

  describe "gateway status" do
    test "shows gateway status with running endpoint" do
      output = capture_io(fn -> Gateway.run(["status"], []) end)
      assert output =~ "Gateway Status"
      # Endpoint is running in test (even if server: false)
      assert output =~ "Status:"
      assert output =~ "Port:"
    end

    test "shows port number" do
      output = capture_io(fn -> Gateway.run(["status"], []) end)
      assert output =~ "Port:"
    end

    test "shows URL" do
      output = capture_io(fn -> Gateway.run(["status"], []) end)
      assert output =~ "URL:"
    end

    test "shows auth status" do
      output = capture_io(fn -> Gateway.run(["status"], []) end)
      assert output =~ "Auth:"
    end

    test "shows help with --help flag" do
      output = capture_io(fn -> Gateway.run(["status"], [help: true]) end)
      assert output =~ "Usage:"
      assert output =~ "gateway status"
    end
  end

  describe "gateway restart" do
    test "refuses to restart in test environment" do
      # env: :test is configured in test.exs
      output = capture_io(fn -> Gateway.run(["restart"], []) end)
      assert output =~ "Cannot restart gateway in test environment"
    end

    test "shows help with --help flag" do
      output = capture_io(fn -> Gateway.run(["restart"], [help: true]) end)
      assert output =~ "Usage:"
      assert output =~ "gateway restart"
    end
  end

  describe "gateway help" do
    test "shows help with no args" do
      output = capture_io(fn -> Gateway.run([], []) end)
      assert output =~ "Usage:"
      assert output =~ "status"
      assert output =~ "restart"
    end

    test "shows help with --help flag" do
      output = capture_io(fn -> Gateway.run(["--help"], []) end)
      assert output =~ "Usage:"
    end

    test "shows error for unknown subcommand" do
      output = capture_io(fn -> Gateway.run(["unknown"], []) end)
      assert output =~ "Unknown gateway subcommand"
    end
  end
end
