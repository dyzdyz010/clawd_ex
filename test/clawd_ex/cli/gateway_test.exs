defmodule ClawdEx.CLI.GatewayTest do
  use ClawdEx.DataCase, async: false

  alias ClawdEx.CLI.Gateway

  import ExUnit.CaptureIO

  test "gateway status shows key info" do
    output = capture_io(fn -> Gateway.run(["status"], []) end)
    assert output =~ "Gateway Status"
    assert output =~ "Status:"
    assert output =~ "Port:"
    assert output =~ "URL:"
    assert output =~ "Auth:"
  end

  test "gateway restart refuses in test environment" do
    output = capture_io(fn -> Gateway.run(["restart"], []) end)
    assert output =~ "Cannot restart gateway in test environment"
  end

  test "shows help with no args or --help" do
    for args <- [[], ["--help"]] do
      output = capture_io(fn -> Gateway.run(args, []) end)
      assert output =~ "Usage:"
    end
  end

  test "shows error for unknown subcommand" do
    output = capture_io(fn -> Gateway.run(["unknown"], []) end)
    assert output =~ "Unknown gateway subcommand"
  end
end
