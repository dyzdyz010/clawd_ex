defmodule ClawdEx.Channels.TelegramTest do
  use ExUnit.Case, async: true

  alias ClawdEx.Channels.Telegram

  describe "name/0" do
    test "returns telegram" do
      assert Telegram.name() == "telegram"
    end
  end

  describe "send_message/3" do
    test "returns error when bot not configured" do
      # When no token is set, send_message should return error
      # This tests the behavior when Telegram GenServer isn't running
      result = Telegram.send_message("123456", "Hello")
      assert {:error, _reason} = result
    end
  end

  describe "format_message (private)" do
    # We can't directly test private functions, but we can verify
    # the public interface handles various message formats correctly
  end

  describe "TelegramSupervisor" do
    alias ClawdEx.Channels.TelegramSupervisor

    test "ready? returns false when not started" do
      # When supervisor isn't running, ready? should return false
      refute TelegramSupervisor.ready?()
    end
  end
end
