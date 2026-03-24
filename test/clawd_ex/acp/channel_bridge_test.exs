defmodule ClawdEx.ACP.ChannelBridgeTest do
  use ClawdEx.DataCase, async: false

  alias ClawdEx.ACP.{ChannelBridge, Event}

  describe "handle_event/2" do
    test "text_delta events return :ok (accumulated by session)" do
      state = build_session_state()
      event = Event.text_delta("hello")
      assert :ok = ChannelBridge.handle_event(state, event)
    end

    test "tool_call events broadcast via PubSub" do
      state = build_session_state()
      parent_key = state.parent_session_key

      Phoenix.PubSub.subscribe(ClawdEx.PubSub, "session:#{parent_key}")

      event = Event.tool_call("call_123", tool_title: "read_file", tool_status: "running")
      assert :ok = ChannelBridge.handle_event(state, event)

      assert_receive {:acp_channel_event, %{type: :tool_call, message: msg}}, 1_000
      assert msg =~ "正在执行"
      assert msg =~ "read_file"
    end

    test "status events broadcast via PubSub" do
      state = build_session_state()
      parent_key = state.parent_session_key

      Phoenix.PubSub.subscribe(ClawdEx.PubSub, "session:#{parent_key}")

      event = Event.status("thinking...")
      assert :ok = ChannelBridge.handle_event(state, event)

      assert_receive {:acp_channel_event, %{type: :status, message: msg}}, 1_000
      assert msg =~ "thinking..."
    end

    test "done events return :ok (handled by announce_completion)" do
      state = build_session_state()
      event = Event.done(stop_reason: "end_turn")
      assert :ok = ChannelBridge.handle_event(state, event)
    end

    test "error events handle gracefully with nil channel" do
      state = build_session_state(%{channel: nil, channel_to: nil})
      event = Event.error("test_error", text: "something went wrong")
      assert :ok = ChannelBridge.handle_event(state, event)
    end
  end

  describe "announce_completion/3" do
    test "formats success message correctly" do
      state = build_session_state(%{channel: nil})
      result = {:ok, "Task completed successfully"}
      assert :ok = ChannelBridge.announce_completion(state, result, 5_000)
    end

    test "formats error message correctly" do
      state = build_session_state(%{channel: nil})
      result = {:error, "something failed"}
      assert :ok = ChannelBridge.announce_completion(state, result, 10_000)
    end

    test "formats timeout message correctly" do
      state = build_session_state(%{channel: nil})
      result = {:error, :timeout}
      assert :ok = ChannelBridge.announce_completion(state, result, 600_000)
    end

    test "handles empty ok result" do
      state = build_session_state(%{channel: nil})
      result = {:ok, ""}
      assert :ok = ChannelBridge.announce_completion(state, result, 1_000)
    end
  end

  # Helper to build a mock session state struct
  defp build_session_state(overrides \\ %{}) do
    defaults = %{
      session_key: "agent:test:acp:bridge-test",
      agent_id: "codex",
      label: "bridge-test",
      parent_session_key: "agent:test:parent:#{System.unique_integer([:positive])}",
      parent_session_id: nil,
      channel: "test",
      channel_to: "test-channel-123",
      mode: "run"
    }

    Map.merge(defaults, overrides)
  end
end
