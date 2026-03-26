defmodule ClawdEx.CLI.ModelsTest do
  use ClawdEx.DataCase, async: true

  alias ClawdEx.CLI.Models

  import ExUnit.CaptureIO

  test "models list shows providers, models, and capabilities" do
    output = capture_io(fn -> Models.run(["list"], []) end)

    assert output =~ "Available Models"
    # Providers
    assert output =~ "ANTHROPIC"
    assert output =~ "OPENAI"
    assert output =~ "GOOGLE"
    # Model IDs
    assert output =~ "anthropic/claude-opus-4-5"
    assert output =~ "openai/gpt-5.2"
    # Aliases
    assert output =~ "opus"
    assert output =~ "sonnet"
    # Capabilities
    assert output =~ "chat"
    assert output =~ "vision"
    assert output =~ "tools"
    # Count
    assert output =~ "Total:"
    assert output =~ "models across"
  end

  test "shows help with no args or --help" do
    for args <- [[], ["--help"]] do
      output = capture_io(fn -> Models.run(args, []) end)
      assert output =~ "Usage:"
    end
  end

  test "shows error for unknown subcommand" do
    output = capture_io(fn -> Models.run(["unknown"], []) end)
    assert output =~ "Unknown models subcommand"
  end

  test "configured_providers returns a list including ollama" do
    providers = Models.configured_providers()
    assert is_list(providers)
    assert :ollama in providers
  end
end
