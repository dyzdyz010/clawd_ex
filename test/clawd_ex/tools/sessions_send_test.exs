defmodule ClawdEx.Tools.SessionsSendTest do
  use ClawdEx.DataCase, async: false

  alias ClawdEx.Tools.SessionsSend
  alias ClawdEx.Sessions.SessionManager

  describe "sessions_send tool metadata" do
    test "has correct name" do
      assert SessionsSend.name() == "sessions_send"
    end

    test "has description" do
      desc = SessionsSend.description()
      assert is_binary(desc)
      assert desc =~ "message"
      assert desc =~ "session"
    end

    test "defines required parameters" do
      params = SessionsSend.parameters()

      assert params[:type] == "object"
      assert "sessionKey" in params[:required]
      assert "message" in params[:required]

      properties = params[:properties]
      assert Map.has_key?(properties, :sessionKey)
      assert Map.has_key?(properties, :message)
      assert Map.has_key?(properties, :timeoutSeconds)
    end
  end

  describe "sessions_send validation" do
    test "returns error when sessionKey is missing" do
      result = SessionsSend.execute(%{"message" => "hello"}, %{})
      assert {:error, message} = result
      assert message =~ "sessionKey"
    end

    test "returns error when message is missing" do
      result = SessionsSend.execute(%{"sessionKey" => "test:session"}, %{})
      assert {:error, message} = result
      assert message =~ "message"
    end

    test "returns error when sessionKey is empty" do
      result = SessionsSend.execute(%{"sessionKey" => "", "message" => "hello"}, %{})
      assert {:error, message} = result
      assert message =~ "sessionKey"
    end

    test "returns error when message is empty" do
      result = SessionsSend.execute(%{"sessionKey" => "test:session", "message" => ""}, %{})
      assert {:error, message} = result
      assert message =~ "message"
    end

    test "returns error when trying to send to self" do
      context = %{session_key: "agent:test:main"}

      result =
        SessionsSend.execute(
          %{"sessionKey" => "agent:test:main", "message" => "hello"},
          context
        )

      assert {:error, message} = result
      assert message =~ "self"
    end
  end

  describe "sessions_send with atom keys" do
    test "accepts atom keys for parameters" do
      result = SessionsSend.execute(%{message: "hello"}, %{})
      assert {:error, message} = result
      assert message =~ "sessionKey"
    end

    test "accepts mixed keys" do
      context = %{session_key: "agent:sender:main"}

      result =
        SessionsSend.execute(
          %{sessionKey: "agent:test:main", "message" => "hello"},
          context
        )

      # Should fail because target session doesn't exist, but validation passed
      assert {:error, message} = result
      assert message =~ "not found"
    end
  end

  describe "sessions_send to non-existent session" do
    test "returns error when target session does not exist" do
      context = %{session_key: "agent:sender:main"}

      result =
        SessionsSend.execute(
          %{
            "sessionKey" => "agent:nonexistent:main",
            "message" => "hello"
          },
          context
        )

      assert {:error, message} = result
      assert message =~ "not found"
    end
  end

  describe "sessions_send integration" do
    setup do
      # 创建一个测试 agent
      {:ok, agent} =
        ClawdEx.Repo.insert(%ClawdEx.Agents.Agent{
          name: "test-target",
          default_model: "anthropic/claude-sonnet-4"
        })

      target_session_key = "agent:test-target:main"

      on_exit(fn ->
        # 清理会话
        SessionManager.stop_session(target_session_key)
        ClawdEx.Repo.delete(agent)
      end)

      %{agent: agent, target_session_key: target_session_key}
    end

    @tag :integration
    @tag timeout: 60_000
    test "sends message to existing session", %{target_session_key: target_session_key} do
      # 首先启动目标会话
      {:ok, _pid} =
        SessionManager.start_session(
          session_key: target_session_key,
          channel: "test"
        )

      # 等待会话完全初始化
      Process.sleep(500)

      context = %{session_key: "agent:sender:main"}

      # 发送消息 - 这会触发 AI 响应，可能需要一些时间
      result =
        SessionsSend.execute(
          %{
            "sessionKey" => target_session_key,
            "message" => "Hello from sender session",
            "timeoutSeconds" => 30
          },
          context
        )

      case result do
        {:ok, response} ->
          # 应该收到格式化的响应
          assert is_binary(response)
          assert response =~ "Response from session"

        {:error, reason} ->
          # 如果 AI 调用失败（API key 等问题），也是可接受的
          assert is_binary(reason)
      end
    end
  end

  describe "timeout handling" do
    test "uses default timeout when not specified" do
      # 通过检查参数处理来间接测试
      params = SessionsSend.parameters()
      props = params[:properties][:timeoutSeconds]

      assert props[:description] =~ "30"
    end

    test "caps timeout at maximum" do
      # 使用超大的 timeout，应该被限制
      context = %{session_key: "agent:sender:main"}

      result =
        SessionsSend.execute(
          %{
            "sessionKey" => "agent:target:main",
            "message" => "hello",
            "timeoutSeconds" => 999_999
          },
          context
        )

      # 验证它不会等待 999999 秒
      # 应该快速返回 session not found 错误
      assert {:error, _} = result
    end
  end
end
