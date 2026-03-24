defmodule ClawdEx.Commands.HandlerTest do
  use ClawdEx.DataCase, async: true

  alias ClawdEx.Commands.Handler

  describe "command?/1" do
    test "recognizes known commands" do
      assert Handler.command?("/new")
      assert Handler.command?("/reset")
      assert Handler.command?("/status")
      assert Handler.command?("/model")
      assert Handler.command?("/help")
      assert Handler.command?("/compact")
      assert Handler.command?("/version")
    end

    test "recognizes commands with bot username suffix" do
      assert Handler.command?("/help@my_bot")
      assert Handler.command?("/status@openclaw_ex_bot")
      assert Handler.command?("/model@some_bot")
    end

    test "recognizes commands with arguments" do
      assert Handler.command?("/model list")
      assert Handler.command?("/model anthropic/claude-sonnet-4-5")
    end

    test "rejects non-command messages" do
      refute Handler.command?("hello")
      refute Handler.command?("how are you?")
      refute Handler.command?("what is /help")
      refute Handler.command?("")
    end

    test "rejects unknown commands" do
      refute Handler.command?("/unknown")
      refute Handler.command?("/foo")
    end

    test "handles non-string input" do
      refute Handler.command?(nil)
      refute Handler.command?(42)
      refute Handler.command?(%{})
    end
  end

  describe "handle/2 - /help" do
    test "returns help text" do
      {:ok, response} = Handler.handle("/help", %{})
      assert response =~ "可用命令"
      assert response =~ "/new"
      assert response =~ "/status"
      assert response =~ "/model"
      assert response =~ "/compact"
      assert response =~ "/version"
    end
  end

  describe "handle/2 - /version" do
    test "returns version info" do
      {:ok, response} = Handler.handle("/version", %{})
      assert response =~ "ClawdEx"
      assert response =~ "Build:"
    end
  end

  describe "handle/2 - /new" do
    test "returns reset message when no session_key" do
      {:ok, response} = Handler.handle("/new", %{})
      assert response =~ "会话已重置"
    end

    test "returns no active session message for unknown session" do
      {:ok, response} = Handler.handle("/new", %{session_key: "telegram:nonexistent_999"})
      assert response =~ "没有活跃会话"
    end
  end

  describe "handle/2 - /reset" do
    test "behaves same as /new" do
      {:ok, response} = Handler.handle("/reset", %{})
      assert response =~ "会话已重置"
    end
  end

  describe "handle/2 - /status" do
    test "returns no session message when no session_key" do
      {:ok, response} = Handler.handle("/status", %{})
      assert response =~ "没有活跃会话"
    end

    test "returns no session message for unknown session" do
      {:ok, response} = Handler.handle("/status", %{session_key: "telegram:nonexistent_999"})
      assert response =~ "没有活跃会话"
    end
  end

  describe "handle/2 - /model" do
    test "shows current model when no args and no session" do
      {:ok, response} = Handler.handle("/model", %{})
      assert response =~ "当前模型"
      assert response =~ "/model list"
    end

    test "/model list returns available models" do
      {:ok, response} = Handler.handle("/model list", %{})
      assert response =~ "可用模型"
      # Should contain at least one model
      assert response =~ "anthropic/"
    end

    test "/model <name> with no active session returns warning" do
      {:ok, response} =
        Handler.handle("/model anthropic/claude-sonnet-4-5", %{
          session_key: "telegram:nonexistent_999"
        })

      assert response =~ "没有活跃会话"
    end
  end

  describe "handle/2 - /compact" do
    test "returns no session message when no active session" do
      {:ok, response} =
        Handler.handle("/compact", %{session_key: "telegram:nonexistent_999"})

      assert response =~ "没有活跃会话"
    end
  end

  describe "handle/2 - unknown command" do
    test "returns unknown command message" do
      {:ok, response} = Handler.handle("/nonexistent", %{})
      assert response =~ "未知命令"
    end
  end
end
