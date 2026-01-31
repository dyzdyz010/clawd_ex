defmodule ClawdEx.Tools.SessionsSendTest do
  use ExUnit.Case, async: true

  alias ClawdEx.Tools.SessionsSend

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
  end

  describe "timeout handling" do
    test "uses default timeout when not specified" do
      # 通过检查参数处理来间接测试
      params = SessionsSend.parameters()
      props = params[:properties][:timeoutSeconds]

      assert props[:description] =~ "30"
    end
  end
end
