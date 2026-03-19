defmodule ClawdEx.Tools.GatewayBroadcastTest do
  use ExUnit.Case, async: false

  alias ClawdEx.Tools.Gateway

  @moduletag :gateway_broadcast

  describe "execute/2 - broadcast" do
    test "broadcasts message to all active sessions" do
      # Subscribe to the global broadcast topic to verify PubSub
      Phoenix.PubSub.subscribe(ClawdEx.PubSub, "sessions:broadcast")

      result = Gateway.execute(%{"action" => "broadcast", "message" => "Hello everyone!"}, %{})

      assert {:ok, %{status: "broadcasted", sessions_notified: count, message: "Hello everyone!"}} =
               result

      assert is_integer(count)
      assert count >= 0

      # Verify we received the global broadcast message
      assert_receive {:broadcast_message, "Hello everyone!"}, 1000
    end

    test "broadcasts to individual session topics" do
      # Register a fake session in the Registry
      session_key = "broadcast-test-session-#{System.unique_integer([:positive])}"
      {:ok, _} = Registry.register(ClawdEx.SessionRegistry, session_key, %{})

      # Subscribe to the individual session topic
      Phoenix.PubSub.subscribe(ClawdEx.PubSub, "session:#{session_key}")

      result = Gateway.execute(%{"action" => "broadcast", "message" => "targeted msg"}, %{})

      assert {:ok, %{status: "broadcasted", sessions_notified: count}} = result
      assert count >= 1

      # Verify we received the per-session system message
      assert_receive {:system_message, "targeted msg"}, 1000

      # Cleanup
      Registry.unregister(ClawdEx.SessionRegistry, session_key)
    end

    test "returns error when message is missing" do
      assert {:error, msg} = Gateway.execute(%{"action" => "broadcast"}, %{})
      assert String.contains?(msg, "message parameter is required")
    end

    test "returns error when message is nil" do
      assert {:error, msg} =
               Gateway.execute(%{"action" => "broadcast", "message" => nil}, %{})

      assert String.contains?(msg, "message parameter is required")
    end

    test "reports correct session count" do
      # Register multiple fake sessions
      keys =
        for i <- 1..3 do
          key = "broadcast-count-test-#{i}-#{System.unique_integer([:positive])}"
          {:ok, _} = Registry.register(ClawdEx.SessionRegistry, key, %{})
          key
        end

      result = Gateway.execute(%{"action" => "broadcast", "message" => "count test"}, %{})
      assert {:ok, %{sessions_notified: count}} = result
      assert count >= 3

      # Cleanup
      Enum.each(keys, fn key ->
        Registry.unregister(ClawdEx.SessionRegistry, key)
      end)
    end
  end

  describe "parameters/0 - broadcast" do
    test "includes broadcast in action enum" do
      params = Gateway.parameters()
      action_enum = params[:properties][:action][:enum]
      assert "broadcast" in action_enum
    end

    test "includes message property" do
      params = Gateway.parameters()
      assert params[:properties][:message]
      assert params[:properties][:message][:type] == "string"
    end
  end
end
