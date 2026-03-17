defmodule ClawdEx.CLI.ModelsTest do
  use ClawdEx.DataCase, async: true

  alias ClawdEx.CLI.Models

  import ExUnit.CaptureIO

  describe "models list" do
    test "lists all models grouped by provider" do
      output = capture_io(fn -> Models.run(["list"], []) end)
      assert output =~ "Available Models"
      assert output =~ "ANTHROPIC"
      assert output =~ "OPENAI"
      assert output =~ "GOOGLE"
      assert output =~ "GROQ"
      assert output =~ "OLLAMA"
    end

    test "shows model IDs" do
      output = capture_io(fn -> Models.run(["list"], []) end)
      assert output =~ "anthropic/claude-opus-4-5"
      assert output =~ "openai/gpt-5.2"
      assert output =~ "google/gemini-3-pro"
    end

    test "shows aliases" do
      output = capture_io(fn -> Models.run(["list"], []) end)
      assert output =~ "opus"
      assert output =~ "sonnet"
    end

    test "shows capabilities" do
      output = capture_io(fn -> Models.run(["list"], []) end)
      assert output =~ "chat"
      assert output =~ "vision"
      assert output =~ "tools"
    end

    test "shows total count" do
      output = capture_io(fn -> Models.run(["list"], []) end)
      assert output =~ "Total:"
      assert output =~ "models across"
      assert output =~ "providers"
    end

    test "shows configuration status" do
      output = capture_io(fn -> Models.run(["list"], []) end)
      # In test env, most providers won't be configured
      assert output =~ "configured" or output =~ "not configured"
    end

    test "shows help with --help flag" do
      output = capture_io(fn -> Models.run(["list"], [help: true]) end)
      assert output =~ "Usage:"
      assert output =~ "models list"
    end
  end

  describe "models help" do
    test "shows help with no args" do
      output = capture_io(fn -> Models.run([], []) end)
      assert output =~ "Usage:"
      assert output =~ "list"
    end

    test "shows help with --help flag" do
      output = capture_io(fn -> Models.run(["--help"], []) end)
      assert output =~ "Usage:"
    end

    test "shows error for unknown subcommand" do
      output = capture_io(fn -> Models.run(["unknown"], []) end)
      assert output =~ "Unknown models subcommand"
    end
  end

  describe "configured_providers/0" do
    test "returns a list" do
      providers = Models.configured_providers()
      assert is_list(providers)
    end

    test "includes ollama when configured" do
      # Ollama is configured by default in config.exs
      providers = Models.configured_providers()
      assert :ollama in providers
    end
  end
end
