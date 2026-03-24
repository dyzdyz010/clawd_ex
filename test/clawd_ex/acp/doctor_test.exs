defmodule ClawdEx.ACP.DoctorTest do
  use ExUnit.Case, async: true

  alias ClawdEx.ACP.Doctor

  describe "check/0" do
    test "returns agents list and summary" do
      result = Doctor.check()
      assert is_list(result.agents)
      assert is_binary(result.summary)
      assert length(result.agents) == length(Doctor.known_agents())

      # Every entry is a {name, status} tuple
      for {name, status} <- result.agents do
        assert is_binary(name)
        assert is_boolean(status.available)

        if status.available do
          assert is_binary(status.path)
        else
          assert status.path == nil
        end
      end
    end

    test "known agents include claude, codex, gemini, pi" do
      agents = Doctor.known_agents()
      assert "claude" in agents
      assert "codex" in agents
      assert "gemini" in agents
      assert "pi" in agents
    end
  end

  describe "check_agent/1" do
    test "returns available status for an installed agent" do
      # We know `ls` exists on every Unix system, but we test with the actual
      # agent names — at least one should be available on this dev machine
      result = Doctor.check_agent("ls")
      # ls is always there
      assert result.available == true
      assert is_binary(result.path)
    end

    test "returns unavailable for a nonexistent agent" do
      result = Doctor.check_agent("totally_fake_agent_xyz_999")
      assert result.available == false
      assert result.path == nil
      assert result.version == nil
    end
  end

  describe "extract_version/1" do
    test "extracts semver from 'tool v1.2.3' format" do
      assert Doctor.extract_version("claude v2.1.76") == "2.1.76"
    end

    test "extracts semver from 'tool 1.2.3' format" do
      assert Doctor.extract_version("codex 0.110.0") == "0.110.0"
    end

    test "extracts semver from bare version" do
      assert Doctor.extract_version("0.28.2\n") == "0.28.2"
    end

    test "extracts semver with pre-release suffix" do
      assert Doctor.extract_version("v1.0.0-beta.1") == "1.0.0-beta.1"
    end

    test "returns nil for no version found" do
      assert Doctor.extract_version("no version here") == nil
    end

    test "extracts from multiline output" do
      output = """
      Some CLI tool
      Version: 3.2.1
      Built on 2025-01-01
      """

      assert Doctor.extract_version(output) == "3.2.1"
    end
  end

  describe "format_summary (via check/0)" do
    test "summary includes available/not-found sections" do
      result = Doctor.check()
      summary = result.summary

      assert summary =~ "✅" or summary =~ "⚠️" or summary =~ "❌"
    end
  end
end
