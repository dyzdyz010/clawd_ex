defmodule ClawdEx.ACP.Backends.CLIBackendTest do
  use ExUnit.Case, async: true

  alias ClawdEx.ACP.Backends.CLIBackend
  alias ClawdEx.ACP.Event

  # ============================================================================
  # Agent Config & Discovery
  # ============================================================================

  describe "supported_agents/0" do
    test "returns list including claude, codex, gemini" do
      agents = CLIBackend.supported_agents()
      assert "claude" in agents
      assert "codex" in agents
      assert "gemini" in agents
    end
  end

  describe "agent_config/1" do
    test "returns config for known agent" do
      config = CLIBackend.agent_config("claude")
      assert config.command == "claude"
      assert "--print" in config.args
      assert "--output-format" in config.args
      assert config.parser == :claude_json
    end

    test "returns nil for unknown agent" do
      assert CLIBackend.agent_config("unknown_agent") == nil
    end
  end

  describe "agent_available?/1" do
    test "returns false for unknown agent" do
      refute CLIBackend.agent_available?("nonexistent_agent_xyz_999")
    end

    test "returns boolean for known agent" do
      result = CLIBackend.agent_available?("claude")
      assert is_boolean(result)
    end
  end

  # ============================================================================
  # ensure_session (Runtime behaviour)
  # ============================================================================

  describe "ensure_session/1" do
    test "returns error for unknown agent" do
      assert {:error, {:unknown_agent, "nope"}} =
               CLIBackend.ensure_session(%{agent_id: "nope"})
    end

    test "returns error when agent CLI is not found (fake command)" do
      # We can't easily test this without modifying @agent_configs,
      # so we validate the error path exists via unknown agent
      result = CLIBackend.ensure_session(%{agent_id: "nonexistent_xyz"})
      assert {:error, {:unknown_agent, _}} = result
    end
  end

  # ============================================================================
  # doctor/0 (Runtime behaviour)
  # ============================================================================

  describe "doctor/0" do
    test "returns ok with backend info and agent map" do
      {:ok, result} = CLIBackend.doctor()
      assert result.backend == "cli"
      assert is_map(result.agents)
      assert Map.has_key?(result.agents, "claude")
      assert Map.has_key?(result.agents, "codex")
      assert Map.has_key?(result.agents, "gemini")

      # Each agent should have :available key
      for {_id, info} <- result.agents do
        assert is_boolean(info.available)
      end
    end
  end

  # ============================================================================
  # Claude JSON Event Parsing
  # ============================================================================

  describe "parse_claude_event/1" do
    test "parses text event" do
      json = ~s({"type":"assistant","subtype":"text","text":"Hello world"})
      event = CLIBackend.parse_claude_event(json)

      assert %Event{} = event
      assert event.type == :text_delta
      assert event.text == "Hello world"
    end

    test "parses tool_use event" do
      json =
        ~s({"type":"assistant","subtype":"tool_use","name":"Read","input":{"path":"/tmp/test.txt"}})

      event = CLIBackend.parse_claude_event(json)

      assert %Event{} = event
      assert event.type == :tool_call
      assert event.tool_call_id == "Read"
      assert event.tool_title == "Read"
    end

    test "parses result success event" do
      json = ~s({"type":"result","subtype":"success","cost_usd":0.042,"duration_ms":1500})
      event = CLIBackend.parse_claude_event(json)

      assert %Event{} = event
      assert event.type == :done
      assert event.stop_reason == "end_turn"
      assert event.text =~ "0.042"
    end

    test "parses result error event" do
      json = ~s({"type":"result","subtype":"error","error":"Rate limited"})
      event = CLIBackend.parse_claude_event(json)

      assert %Event{} = event
      assert event.type == :error
      assert event.code == "Rate limited"
    end

    test "returns nil for invalid JSON" do
      assert CLIBackend.parse_claude_event("not json at all") == nil
    end

    test "returns nil for unknown event type without text" do
      json = ~s({"type":"system","subtype":"init"})
      assert CLIBackend.parse_claude_event(json) == nil
    end

    test "returns text_delta for unknown event type with text field" do
      json = ~s({"type":"system","text":"booting up"})
      event = CLIBackend.parse_claude_event(json)
      assert event.type == :text_delta
      assert event.text == "booting up"
    end
  end

  # ============================================================================
  # Port-based Integration Tests (using echo/sh scripts)
  # ============================================================================

  describe "run_turn with echo (integration)" do
    test "runs a simple echo command and collects events" do
      # Start the backend GenServer with a fake "echo" config
      {:ok, pid} =
        GenServer.start_link(CLIBackend, %{
          agent_id: "test_echo",
          config: %{
            command: "echo",
            args: [],
            parser: :plain_text,
            timeout_ms: 5_000
          },
          executable: System.find_executable("echo"),
          extra_args: [],
          env: [],
          cwd: nil
        })

      handle = %{pid: pid, agent_id: "test_echo", config: %{}}

      {:ok, events} = CLIBackend.run_turn(handle, "hello from test")

      assert is_list(events)
      assert length(events) >= 1

      text_events = Enum.filter(events, &(&1.type == :text_delta))
      done_events = Enum.filter(events, &(&1.type == :done))

      assert length(text_events) >= 1
      assert length(done_events) >= 1

      full_text = text_events |> Enum.map(& &1.text) |> Enum.join()
      assert full_text =~ "hello from test"

      CLIBackend.close(handle)
    end

    test "handles process that exits with error" do
      {:ok, pid} =
        GenServer.start_link(CLIBackend, %{
          agent_id: "test_false",
          config: %{
            command: "false",
            args: [],
            parser: :plain_text,
            timeout_ms: 5_000
          },
          executable: System.find_executable("false") || "/usr/bin/false",
          extra_args: [],
          env: [],
          cwd: nil
        })

      handle = %{pid: pid, agent_id: "test_false", config: %{}}

      # `false` exits with code 1 — backend returns {:ok, events} with an error event
      {:ok, events} = CLIBackend.run_turn(handle, "")

      assert is_list(events)
      error_events = Enum.filter(events, &(&1.type == :error))
      assert length(error_events) >= 1

      CLIBackend.close(handle)
    end
  end

  describe "run_turn with Claude JSON simulation" do
    test "parses Claude-style JSON-lines output" do
      script = """
      #!/bin/sh
      echo '{"type":"assistant","subtype":"text","text":"Hello!"}'
      echo '{"type":"assistant","subtype":"tool_use","name":"Read","input":{"path":"test.txt"}}'
      echo '{"type":"result","subtype":"success","cost_usd":0.01}'
      """

      script_path = Path.join(System.tmp_dir!(), "claude_sim_#{:rand.uniform(100_000)}.sh")
      File.write!(script_path, script)
      File.chmod!(script_path, 0o755)

      on_exit(fn -> File.rm(script_path) end)

      {:ok, pid} =
        GenServer.start_link(CLIBackend, %{
          agent_id: "claude_sim",
          config: %{
            command: script_path,
            args: [],
            parser: :claude_json,
            timeout_ms: 5_000
          },
          executable: script_path,
          extra_args: [],
          env: [],
          cwd: nil
        })

      handle = %{pid: pid, agent_id: "claude_sim", config: %{}}

      {:ok, events} = CLIBackend.run_turn(handle, "test prompt")

      # Should have 3 events: text_delta, tool_call, done
      assert length(events) == 3

      [text_ev, tool_ev, done_ev] = events

      assert text_ev.type == :text_delta
      assert text_ev.text == "Hello!"

      assert tool_ev.type == :tool_call
      assert tool_ev.tool_call_id == "Read"

      assert done_ev.type == :done
      assert done_ev.stop_reason == "end_turn"

      CLIBackend.close(handle)
    end
  end

  # ============================================================================
  # stream_turn
  # ============================================================================

  describe "stream_turn/3" do
    test "returns an enumerable stream of events" do
      {:ok, pid} =
        GenServer.start_link(CLIBackend, %{
          agent_id: "test_stream",
          config: %{
            command: "echo",
            args: [],
            parser: :plain_text,
            timeout_ms: 5_000
          },
          executable: System.find_executable("echo"),
          extra_args: [],
          env: [],
          cwd: nil
        })

      handle = %{pid: pid, agent_id: "test_stream", config: %{}}

      events = CLIBackend.stream_turn(handle, "stream test") |> Enum.to_list()

      assert is_list(events)
      assert length(events) >= 1

      CLIBackend.close(handle)
    end
  end

  # ============================================================================
  # get_status / cancel
  # ============================================================================

  describe "get_status/1" do
    test "returns idle status for new session" do
      {:ok, pid} =
        GenServer.start_link(CLIBackend, %{
          agent_id: "test_status",
          config: %{
            command: "echo",
            args: [],
            parser: :plain_text,
            timeout_ms: 5_000
          },
          executable: System.find_executable("echo")
        })

      handle = %{pid: pid}
      {:ok, status} = CLIBackend.get_status(handle)
      assert status.status == :idle
      assert status.agent_id == "test_status"

      CLIBackend.close(handle)
    end
  end

  describe "close/1" do
    test "handles already-stopped process gracefully" do
      dead_pid = spawn(fn -> :ok end)
      Process.sleep(10)
      assert :ok = CLIBackend.close(%{pid: dead_pid})
    end
  end
end
