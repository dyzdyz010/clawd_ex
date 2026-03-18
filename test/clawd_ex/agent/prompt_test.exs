defmodule ClawdEx.Agent.PromptTest do
  use ExUnit.Case, async: true

  alias ClawdEx.Agent.Prompt

  describe "build/2" do
    test "returns a non-empty string with no agent and default config" do
      result = Prompt.build(nil, %{})
      assert is_binary(result)
      assert String.length(result) > 0
    end

    test "includes identity section" do
      result = Prompt.build(nil, %{})
      assert result =~ "personal assistant"
    end

    test "includes tooling section with provided tools" do
      tools = [
        %{name: "read"},
        %{name: "write"}
      ]

      result = Prompt.build(nil, %{tools: tools})
      assert result =~ "## Tooling"
      assert result =~ "read"
      assert result =~ "Read file contents"
      assert result =~ "write"
      assert result =~ "Create or overwrite files"
    end

    test "includes tool call style section" do
      result = Prompt.build(nil, %{})
      assert result =~ "## Tool Call Style"
      assert result =~ "CRITICAL: Use Tools"
    end

    test "includes safety section" do
      result = Prompt.build(nil, %{})
      assert result =~ "## Safety"
      assert result =~ "safety and human oversight"
    end

    test "includes silent replies section" do
      result = Prompt.build(nil, %{})
      assert result =~ "## Silent Replies"
      assert result =~ "NO_REPLY"
    end

    test "includes heartbeat section" do
      result = Prompt.build(nil, %{})
      assert result =~ "## Heartbeats"
      assert result =~ "HEARTBEAT_OK"
    end

    test "includes runtime section with model info" do
      config = %{model: "claude-3", channel: "telegram", timezone: "Asia/Shanghai"}
      result = Prompt.build(nil, config)
      assert result =~ "## Runtime"
      assert result =~ "claude-3"
      assert result =~ "telegram"
      assert result =~ "Asia/Shanghai"
    end

    test "includes workspace section with default" do
      result = Prompt.build(nil, %{})
      assert result =~ "## Workspace"
      assert result =~ "~/clawd"
    end

    test "uses custom workspace from config" do
      result = Prompt.build(nil, %{workspace: "/custom/path"})
      assert result =~ "/custom/path"
    end

    test "includes memory section when memory tools present" do
      tools = [%{name: "memory_search"}, %{name: "memory_get"}]
      result = Prompt.build(nil, %{tools: tools})
      assert result =~ "## Memory Recall"
      assert result =~ "memory_search"
    end

    test "excludes memory section when no memory tools" do
      tools = [%{name: "read"}]
      result = Prompt.build(nil, %{tools: tools})
      refute result =~ "## Memory Recall"
    end

    test "includes messaging section when message tool present" do
      tools = [%{name: "message"}]
      result = Prompt.build(nil, %{tools: tools})
      assert result =~ "## Messaging"
    end

    test "excludes messaging section when no message tool" do
      tools = [%{name: "read"}]
      result = Prompt.build(nil, %{tools: tools})
      refute result =~ "## Messaging"
    end

    test "custom heartbeat prompt is included" do
      config = %{heartbeat_prompt: "Check all systems now!"}
      result = Prompt.build(nil, config)
      assert result =~ "Check all systems now!"
    end

    test "different configs produce different prompts" do
      prompt_a = Prompt.build(nil, %{model: "gpt-4", tools: [%{name: "read"}]})
      prompt_b = Prompt.build(nil, %{model: "claude-3", tools: [%{name: "exec"}]})

      refute prompt_a == prompt_b
      assert prompt_a =~ "gpt-4"
      assert prompt_b =~ "claude-3"
      assert prompt_a =~ "read"
      assert prompt_b =~ "exec"
    end

    test "bootstrap section loads files from workspace" do
      # Create a temp workspace with SOUL.md
      tmp_dir = Path.join(System.tmp_dir!(), "prompt_test_#{:rand.uniform(100_000)}")
      File.mkdir_p!(tmp_dir)
      File.write!(Path.join(tmp_dir, "SOUL.md"), "# I am a test soul")

      result = Prompt.build(nil, %{workspace: tmp_dir})
      assert result =~ "# Project Context"
      assert result =~ "I am a test soul"
    after
      # Cleanup
      tmp_dir = Path.join(System.tmp_dir!(), "prompt_test_*")

      Path.wildcard(tmp_dir)
      |> Enum.each(&File.rm_rf!/1)
    end
  end
end
