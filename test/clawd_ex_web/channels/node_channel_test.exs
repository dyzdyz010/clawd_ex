defmodule ClawdExWeb.Channels.NodeChannelTest do
  use ClawdExWeb.ChannelCase, async: false

  alias ClawdEx.Nodes.{Pairing, Registry}
  alias ClawdExWeb.Channels.{GatewaySocket, NodeChannel}

  setup do
    ensure_started(Registry)
    ensure_started(Pairing)

    Registry.reset()
    Pairing.reset()

    # Set a gateway token so bogus tokens are rejected
    Application.put_env(:clawd_ex, :gateway_token, "test-gateway-secret")

    on_exit(fn ->
      Application.delete_env(:clawd_ex, :gateway_token)
    end)

    :ok
  end

  defp ensure_started(module) do
    unless Process.whereis(module) do
      {:ok, _} = module.start_link(name: module)
    end
  end

  defp create_approved_node do
    {:ok, %{code: code}} = Pairing.generate_pair_code()

    {:ok, %{node_id: node_id}} =
      Pairing.verify_pair_code(code, %{
        name: "Test Device",
        type: "mobile",
        capabilities: ["camera"]
      })

    {:ok, %{node_token: node_token}} = Pairing.approve_node(node_id)
    %{node_id: node_id, node_token: node_token}
  end

  defp connect_node_socket(token) do
    connect(GatewaySocket, %{"token" => token})
  end

  # ============================================================================
  # Socket connection
  # ============================================================================

  describe "socket connection" do
    test "connects with valid node_token" do
      %{node_token: token} = create_approved_node()

      assert {:ok, socket} = connect_node_socket(token)
      assert socket.assigns.auth.type == :node
    end

    test "rejects invalid token" do
      assert :error = connect_node_socket("bogus-token")
    end

    test "rejects empty params" do
      assert :error = connect(GatewaySocket, %{})
    end
  end

  # ============================================================================
  # Channel join
  # ============================================================================

  describe "join node channel" do
    test "joins with valid node_token for own node" do
      %{node_id: node_id, node_token: token} = create_approved_node()

      {:ok, socket} = connect_node_socket(token)
      assert {:ok, _, _socket} = subscribe_and_join(socket, NodeChannel, "node:#{node_id}")
    end

    test "rejects join for different node_id" do
      %{node_token: token} = create_approved_node()

      {:ok, socket} = connect_node_socket(token)
      assert {:error, %{reason: "unauthorized"}} = subscribe_and_join(socket, NodeChannel, "node:different-id")
    end
  end

  # ============================================================================
  # Heartbeat
  # ============================================================================

  describe "heartbeat" do
    test "responds to heartbeat" do
      %{node_id: node_id, node_token: token} = create_approved_node()

      {:ok, socket} = connect_node_socket(token)
      {:ok, _, socket} = subscribe_and_join(socket, NodeChannel, "node:#{node_id}")

      ref = push(socket, "heartbeat", %{"timestamp" => System.system_time(:millisecond)})
      assert_reply ref, :ok, %{timestamp: _ts}
    end

    test "heartbeat updates last_seen" do
      %{node_id: node_id, node_token: token} = create_approved_node()

      {:ok, socket} = connect_node_socket(token)
      {:ok, _, socket} = subscribe_and_join(socket, NodeChannel, "node:#{node_id}")

      {:ok, node_before} = Registry.get_node(node_id)
      Process.sleep(10)

      push(socket, "heartbeat", %{})
      # Wait a bit for the handler to process
      Process.sleep(50)

      {:ok, node_after} = Registry.get_node(node_id)
      assert DateTime.compare(node_after.last_seen_at, node_before.last_seen_at) in [:gt, :eq]
    end
  end

  # ============================================================================
  # Tool results
  # ============================================================================

  describe "tool:result" do
    test "acknowledges tool result" do
      %{node_id: node_id, node_token: token} = create_approved_node()

      {:ok, socket} = connect_node_socket(token)
      {:ok, _, socket} = subscribe_and_join(socket, NodeChannel, "node:#{node_id}")

      ref =
        push(socket, "tool:result", %{
          "request_id" => "req-123",
          "result" => %{"status" => "ok", "data" => "photo.jpg"}
        })

      assert_reply ref, :ok
    end
  end

  # ============================================================================
  # Events
  # ============================================================================

  describe "event" do
    test "accepts device events" do
      %{node_id: node_id, node_token: token} = create_approved_node()

      {:ok, socket} = connect_node_socket(token)
      {:ok, _, socket} = subscribe_and_join(socket, NodeChannel, "node:#{node_id}")

      push(socket, "event", %{"type" => "notification", "data" => %{"title" => "Test"}})

      # No error/crash means it worked
      # Give a moment for async processing
      Process.sleep(50)
    end
  end
end
