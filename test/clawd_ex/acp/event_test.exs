defmodule ClawdEx.ACP.EventTest do
  use ExUnit.Case, async: true

  alias ClawdEx.ACP.Event

  describe "text_delta/2" do
    test "creates a text_delta event" do
      event = Event.text_delta("hello")
      assert event.type == :text_delta
      assert event.text == "hello"
      assert event.stream == "output"
    end

    test "accepts keyword opts" do
      event = Event.text_delta("hello", stream: "stderr", tag: "init")
      assert event.stream == "stderr"
      assert event.tag == "init"
    end
  end

  describe "tool_call/2" do
    test "creates a tool_call event" do
      event = Event.tool_call("tc_123", tool_title: "Read", text: "reading file")
      assert event.type == :tool_call
      assert event.tool_call_id == "tc_123"
      assert event.tool_title == "Read"
      assert event.text == "reading file"
    end
  end

  describe "done/1" do
    test "creates a done event with stop reason" do
      event = Event.done(stop_reason: "end_turn")
      assert event.type == :done
      assert event.stop_reason == "end_turn"
    end

    test "creates a done event without opts" do
      event = Event.done()
      assert event.type == :done
      assert event.stop_reason == nil
    end
  end

  describe "error/2" do
    test "creates an error event" do
      event = Event.error("rate_limited", text: "Too many requests")
      assert event.type == :error
      assert event.code == "rate_limited"
      assert event.text == "Too many requests"
      assert event.retryable == false
    end

    test "creates a retryable error" do
      event = Event.error("timeout", retryable: true)
      assert event.retryable == true
    end
  end

  describe "status/2" do
    test "creates a status event" do
      event = Event.status("initializing")
      assert event.type == :status
      assert event.text == "initializing"
    end
  end
end
