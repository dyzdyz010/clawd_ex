defmodule ClawdEx.Tools.MessageTest do
  use ExUnit.Case, async: true

  alias ClawdEx.Tools.Message

  describe "message tool metadata" do
    test "has correct name" do
      assert Message.name() == "message"
    end

    test "has description" do
      desc = Message.description()
      assert is_binary(desc)
      assert desc =~ "message"
      assert desc =~ "channel"
    end

    test "defines required parameters" do
      params = Message.parameters()

      assert params[:type] == "object"
      assert "action" in params[:required]
      assert "channel" in params[:required]
      assert "target" in params[:required]

      properties = params[:properties]
      assert Map.has_key?(properties, :action)
      assert Map.has_key?(properties, :channel)
      assert Map.has_key?(properties, :target)
      assert Map.has_key?(properties, :message)
      assert Map.has_key?(properties, :messageId)
      assert Map.has_key?(properties, :emoji)
      assert Map.has_key?(properties, :replyTo)
      assert Map.has_key?(properties, :media)
      assert Map.has_key?(properties, :caption)
    end

    test "action enum contains expected values" do
      params = Message.parameters()
      action_enum = params[:properties][:action][:enum]

      assert "send" in action_enum
      assert "react" in action_enum
      assert "delete" in action_enum
    end

    test "channel enum contains expected values" do
      params = Message.parameters()
      channel_enum = params[:properties][:channel][:enum]

      assert "telegram" in channel_enum
      assert "discord" in channel_enum
    end
  end

  describe "message validation - required params" do
    test "returns error when action is missing" do
      result = Message.execute(%{"channel" => "telegram", "target" => "123"}, %{})
      assert {:error, message} = result
      assert message =~ "action"
    end

    test "returns error when action is empty" do
      result = Message.execute(%{"action" => "", "channel" => "telegram", "target" => "123"}, %{})
      assert {:error, message} = result
      assert message =~ "action"
    end

    test "returns error when channel is missing" do
      result = Message.execute(%{"action" => "send", "target" => "123"}, %{})
      assert {:error, message} = result
      assert message =~ "channel"
    end

    test "returns error when channel is empty" do
      result = Message.execute(%{"action" => "send", "channel" => "", "target" => "123"}, %{})
      assert {:error, message} = result
      assert message =~ "channel"
    end

    test "returns error when target is missing" do
      result = Message.execute(%{"action" => "send", "channel" => "telegram"}, %{})
      assert {:error, message} = result
      assert message =~ "target"
    end

    test "returns error when target is empty" do
      result =
        Message.execute(%{"action" => "send", "channel" => "telegram", "target" => ""}, %{})

      assert {:error, message} = result
      assert message =~ "target"
    end
  end

  describe "message validation - invalid values" do
    test "returns error for invalid action" do
      result =
        Message.execute(
          %{"action" => "invalid", "channel" => "telegram", "target" => "123"},
          %{}
        )

      assert {:error, message} = result
      assert message =~ "Invalid action"
    end

    test "returns error for invalid channel" do
      result =
        Message.execute(
          %{"action" => "send", "channel" => "whatsapp", "target" => "123"},
          %{}
        )

      assert {:error, message} = result
      assert message =~ "Invalid channel"
    end
  end

  describe "send action validation" do
    test "returns error when message is missing for send" do
      result =
        Message.execute(
          %{"action" => "send", "channel" => "telegram", "target" => "123"},
          %{}
        )

      assert {:error, message} = result
      assert message =~ "message" or message =~ "media"
    end
  end

  describe "react action validation" do
    test "returns error when messageId is missing for react" do
      result =
        Message.execute(
          %{"action" => "react", "channel" => "telegram", "target" => "123", "emoji" => "👍"},
          %{}
        )

      assert {:error, message} = result
      assert message =~ "messageId"
    end

    test "returns error when emoji is missing for react" do
      result =
        Message.execute(
          %{
            "action" => "react",
            "channel" => "telegram",
            "target" => "123",
            "messageId" => "456"
          },
          %{}
        )

      assert {:error, message} = result
      assert message =~ "emoji"
    end
  end

  describe "delete action validation" do
    test "returns error when messageId is missing for delete" do
      result =
        Message.execute(
          %{"action" => "delete", "channel" => "telegram", "target" => "123"},
          %{}
        )

      assert {:error, message} = result
      assert message =~ "messageId"
    end

    test "returns error when messageId is empty for delete" do
      result =
        Message.execute(
          %{
            "action" => "delete",
            "channel" => "telegram",
            "target" => "123",
            "messageId" => ""
          },
          %{}
        )

      assert {:error, message} = result
      assert message =~ "messageId"
    end
  end

  describe "message with atom keys" do
    test "accepts atom keys for parameters" do
      result =
        Message.execute(
          %{action: "send", channel: "telegram", target: "123"},
          %{}
        )

      # Should fail on message validation, not key access
      assert {:error, message} = result
      assert message =~ "message" or message =~ "media"
    end
  end

  describe "media type detection" do
    # These tests indirectly verify the media type detection logic
    # by testing that media URLs are accepted

    test "accepts send with media URL" do
      result =
        Message.execute(
          %{
            "action" => "send",
            "channel" => "telegram",
            "target" => "123",
            "media" => "https://example.com/image.jpg"
          },
          %{}
        )

      # Will fail because channel is not ready, but validation passes
      assert {:error, message} = result
      assert message =~ "not ready" or message =~ "Telegram"
    end

    test "accepts send with media and caption" do
      result =
        Message.execute(
          %{
            "action" => "send",
            "channel" => "discord",
            "target" => "123",
            "media" => "https://example.com/video.mp4",
            "caption" => "Check this out!"
          },
          %{}
        )

      # Will fail because channel is not ready, but validation passes
      assert {:error, message} = result
      assert message =~ "not ready" or message =~ "Discord"
    end
  end

  describe "channel readiness check" do
    test "telegram send fails when channel not ready" do
      result =
        Message.execute(
          %{
            "action" => "send",
            "channel" => "telegram",
            "target" => "123",
            "message" => "test"
          },
          %{}
        )

      assert {:error, message} = result
      assert message =~ "not ready" or message =~ "Telegram"
    end

    test "discord send fails when channel not ready" do
      result =
        Message.execute(
          %{
            "action" => "send",
            "channel" => "discord",
            "target" => "123",
            "message" => "test"
          },
          %{}
        )

      assert {:error, message} = result
      assert message =~ "not ready" or message =~ "Discord"
    end
  end
end
