defmodule ClawdEx.Tools.MessageTest do
  use ExUnit.Case, async: true

  alias ClawdEx.Tools.Message

  describe "message validation - required params" do
    test "returns error for missing or empty required fields" do
      # action missing/empty
      assert {:error, msg} = Message.execute(%{"channel" => "telegram", "target" => "123"}, %{})
      assert msg =~ "action"
      assert {:error, msg} = Message.execute(%{"action" => "", "channel" => "telegram", "target" => "123"}, %{})
      assert msg =~ "action"

      # channel missing/empty
      assert {:error, msg} = Message.execute(%{"action" => "send", "target" => "123"}, %{})
      assert msg =~ "channel"
      assert {:error, msg} = Message.execute(%{"action" => "send", "channel" => "", "target" => "123"}, %{})
      assert msg =~ "channel"

      # target missing/empty
      assert {:error, msg} = Message.execute(%{"action" => "send", "channel" => "telegram"}, %{})
      assert msg =~ "target"
      assert {:error, msg} = Message.execute(%{"action" => "send", "channel" => "telegram", "target" => ""}, %{})
      assert msg =~ "target"
    end

    test "returns error for invalid action or channel" do
      assert {:error, msg} = Message.execute(%{"action" => "invalid", "channel" => "telegram", "target" => "123"}, %{})
      assert msg =~ "Invalid action"

      assert {:error, msg} = Message.execute(%{"action" => "send", "channel" => "whatsapp", "target" => "123"}, %{})
      assert msg =~ "Invalid channel"
    end
  end

  describe "send action validation" do
    test "returns error when message is missing for send" do
      result = Message.execute(%{"action" => "send", "channel" => "telegram", "target" => "123"}, %{})
      assert {:error, msg} = result
      assert msg =~ "message" or msg =~ "media"
    end

    test "accepts send with media URL" do
      result = Message.execute(
        %{"action" => "send", "channel" => "telegram", "target" => "123", "media" => "https://example.com/image.jpg"},
        %{}
      )
      assert {:error, msg} = result
      assert msg =~ "not ready" or msg =~ "Telegram"
    end
  end

  describe "react action validation" do
    test "returns error when messageId or emoji is missing" do
      assert {:error, msg} = Message.execute(
        %{"action" => "react", "channel" => "telegram", "target" => "123", "emoji" => "👍"}, %{})
      assert msg =~ "messageId"

      assert {:error, msg} = Message.execute(
        %{"action" => "react", "channel" => "telegram", "target" => "123", "messageId" => "456"}, %{})
      assert msg =~ "emoji"
    end
  end

  describe "delete action validation" do
    test "returns error when messageId is missing or empty" do
      assert {:error, msg} = Message.execute(
        %{"action" => "delete", "channel" => "telegram", "target" => "123"}, %{})
      assert msg =~ "messageId"

      assert {:error, msg} = Message.execute(
        %{"action" => "delete", "channel" => "telegram", "target" => "123", "messageId" => ""}, %{})
      assert msg =~ "messageId"
    end
  end

  describe "channel readiness check" do
    test "send fails when channels not ready" do
      for channel <- ["telegram", "discord"] do
        result = Message.execute(
          %{"action" => "send", "channel" => channel, "target" => "123", "message" => "test"}, %{})
        assert {:error, msg} = result
        assert msg =~ "not ready" or msg =~ "Telegram" or msg =~ "Discord"
      end
    end
  end

  describe "atom keys" do
    test "accepts atom keys for parameters" do
      result = Message.execute(%{action: "send", channel: "telegram", target: "123"}, %{})
      assert {:error, msg} = result
      assert msg =~ "message" or msg =~ "media"
    end
  end
end
