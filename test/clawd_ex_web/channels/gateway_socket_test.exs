defmodule ClawdExWeb.Channels.GatewaySocketTest do
  use ClawdExWeb.ChannelCase, async: false

  alias ClawdExWeb.Channels.GatewaySocket

  setup do
    # Clear all token configs to ensure clean test state
    Application.delete_env(:clawd_ex, :gateway_token)
    Application.delete_env(:clawd_ex, :api_token)

    on_exit(fn ->
      Application.delete_env(:clawd_ex, :gateway_token)
      Application.delete_env(:clawd_ex, :api_token)
    end)

    :ok
  end

  describe "connect/3" do
    test "connects with valid gateway token via gateway_token config" do
      Application.put_env(:clawd_ex, :gateway_token, "test-secret")

      assert {:ok, socket} =
               connect(GatewaySocket, %{"token" => "test-secret"})

      assert socket.assigns.auth.type == :gateway
      assert socket.assigns.auth.user_id == "gateway"
    end

    test "connects with valid api_token config" do
      Application.put_env(:clawd_ex, :api_token, "api-secret")

      assert {:ok, socket} =
               connect(GatewaySocket, %{"token" => "api-secret"})

      assert socket.assigns.auth.type == :gateway
    end

    test "rejects invalid token" do
      Application.put_env(:clawd_ex, :gateway_token, "test-secret")

      assert :error = connect(GatewaySocket, %{"token" => "wrong-token"})
    end

    test "rejects connection without token param" do
      Application.put_env(:clawd_ex, :gateway_token, "test-secret")

      assert :error = connect(GatewaySocket, %{})
    end

    test "allows any token in dev mode (no token configured)" do
      # Both gateway_token and api_token are nil (cleared in setup)
      assert {:ok, socket} =
               connect(GatewaySocket, %{"token" => "anything"})

      assert socket.assigns.auth.type == :gateway
      assert socket.assigns.auth.user_id == "anonymous"
    end

    test "allows any token when gateway_token is empty string" do
      Application.put_env(:clawd_ex, :gateway_token, "")

      assert {:ok, socket} =
               connect(GatewaySocket, %{"token" => "anything"})

      assert socket.assigns.auth.user_id == "anonymous"
    end
  end

  describe "id/1" do
    test "returns gateway:<user_id> for gateway auth" do
      {:ok, socket} = connect(GatewaySocket, %{"token" => "any"})

      assert GatewaySocket.id(socket) == "gateway:anonymous"
    end

    test "returns gateway:gateway for authenticated user" do
      Application.put_env(:clawd_ex, :gateway_token, "real-token")

      {:ok, socket} = connect(GatewaySocket, %{"token" => "real-token"})

      assert GatewaySocket.id(socket) == "gateway:gateway"
    end
  end
end
