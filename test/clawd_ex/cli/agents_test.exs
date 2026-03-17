defmodule ClawdEx.CLI.AgentsTest do
  use ClawdEx.DataCase, async: false

  alias ClawdEx.CLI.Agents
  alias ClawdEx.Agents.Agent

  import ExUnit.CaptureIO

  describe "agents list" do
    test "shows empty message when no agents" do
      output = capture_io(fn -> Agents.run(["list"], []) end)
      assert output =~ "No agents found."
    end

    test "lists agents from database" do
      {:ok, _agent} =
        %Agent{}
        |> Agent.changeset(%{name: "test-list-agent-#{System.unique_integer()}"})
        |> Repo.insert()

      output = capture_io(fn -> Agents.run(["list"], []) end)
      assert output =~ "Agents"
      assert output =~ "test-list-agent-"
      assert output =~ "Total:"
    end

    test "shows agent details: id, name, model, active" do
      {:ok, agent} =
        %Agent{}
        |> Agent.changeset(%{
          name: "detail-agent-#{System.unique_integer()}",
          default_model: "claude-3-opus",
          active: true
        })
        |> Repo.insert()

      output = capture_io(fn -> Agents.run(["list"], []) end)
      assert output =~ "claude-3-opus"
      assert output =~ "✓"
    end

    test "shows help with --help flag" do
      output = capture_io(fn -> Agents.run(["list"], [help: true]) end)
      assert output =~ "Usage:"
      assert output =~ "agents list"
    end
  end

  describe "agents add" do
    test "creates a new agent with just a name" do
      name = "new-agent-#{System.unique_integer()}"
      output = capture_io(fn -> Agents.run(["add", name], []) end)
      assert output =~ "Agent created successfully"
      assert output =~ name
    end

    test "creates agent with model option" do
      name = "model-agent-#{System.unique_integer()}"
      output = capture_io(fn -> Agents.run(["add", name], [model: "gpt-4"]) end)
      assert output =~ "Agent created successfully"
      assert output =~ name
    end

    test "creates agent with system-prompt option" do
      name = "prompt-agent-#{System.unique_integer()}"

      output =
        capture_io(fn ->
          Agents.run(["add", name], [system_prompt: "You are a helpful assistant"])
        end)

      assert output =~ "Agent created successfully"
    end

    test "fails on duplicate name" do
      name = "dup-agent-#{System.unique_integer()}"

      # Create first
      capture_io(fn -> Agents.run(["add", name], []) end)

      # Try duplicate
      output = capture_io(fn -> Agents.run(["add", name], []) end)
      assert output =~ "Failed to create agent"
    end

    test "shows error when name missing" do
      output = capture_io(fn -> Agents.run(["add"], []) end)
      assert output =~ "agent name is required"
    end

    test "shows help with --help flag" do
      output = capture_io(fn -> Agents.run(["add", "x"], [help: true]) end)
      assert output =~ "Usage:"
      assert output =~ "agents add"
    end
  end

  describe "agents help" do
    test "shows help with no args" do
      output = capture_io(fn -> Agents.run([], []) end)
      assert output =~ "Usage:"
      assert output =~ "list"
      assert output =~ "add"
    end

    test "shows help with --help flag" do
      output = capture_io(fn -> Agents.run(["--help"], []) end)
      assert output =~ "Usage:"
    end

    test "shows error for unknown subcommand" do
      output = capture_io(fn -> Agents.run(["unknown"], []) end)
      assert output =~ "Unknown agents subcommand"
    end
  end
end
