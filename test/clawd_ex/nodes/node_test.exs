defmodule ClawdEx.Nodes.NodeTest do
  use ExUnit.Case, async: true

  alias ClawdEx.Nodes.Node

  describe "new/1" do
    test "creates a node with default values" do
      node = Node.new()

      assert node.id != nil
      assert node.name == "Unknown Node"
      assert node.type == "unknown"
      assert node.status == :pending
      assert node.capabilities == []
      assert node.metadata == %{}
      assert node.last_seen_at != nil
    end

    test "creates a node with custom attributes" do
      attrs = %{
        id: "test-node-123",
        name: "My iPhone",
        type: "mobile",
        capabilities: ["camera", "location", "notifications"],
        metadata: %{os: "iOS", version: "17.0"}
      }

      node = Node.new(attrs)

      assert node.id == "test-node-123"
      assert node.name == "My iPhone"
      assert node.type == "mobile"
      assert node.capabilities == ["camera", "location", "notifications"]
      assert node.metadata.os == "iOS"
    end
  end

  describe "update_status/2" do
    test "updates status to connected" do
      node = Node.new(%{name: "Test Node"})
      updated = Node.update_status(node, :connected)

      assert updated.status == :connected
      assert updated.connected_at != nil
      assert updated.last_seen_at != nil
    end

    test "updates status to disconnected" do
      node = Node.new(%{name: "Test Node"}) |> Node.update_status(:connected)
      updated = Node.update_status(node, :disconnected)

      assert updated.status == :disconnected
      assert updated.last_seen_at != nil
    end
  end

  describe "mark_paired/1" do
    test "marks node as paired with connected status" do
      node = Node.new(%{name: "Test Node"})
      paired = Node.mark_paired(node)

      assert paired.status == :connected
      assert paired.paired_at != nil
      assert paired.connected_at != nil
    end
  end

  describe "touch/1" do
    test "updates last_seen_at" do
      node = Node.new(%{name: "Test Node"})
      old_last_seen = node.last_seen_at

      # Sleep briefly to ensure time difference
      Process.sleep(10)

      touched = Node.touch(node)

      assert DateTime.compare(touched.last_seen_at, old_last_seen) in [:gt, :eq]
    end
  end

  describe "has_capability?/2" do
    test "returns true for existing capability" do
      node = Node.new(%{capabilities: ["camera", "location"]})

      assert Node.has_capability?(node, "camera") == true
      assert Node.has_capability?(node, "location") == true
    end

    test "returns false for missing capability" do
      node = Node.new(%{capabilities: ["camera"]})

      assert Node.has_capability?(node, "microphone") == false
    end
  end

  describe "describe/1" do
    test "returns a map representation" do
      node =
        Node.new(%{
          id: "test-123",
          name: "Test Node",
          type: "mobile",
          capabilities: ["camera"]
        })

      desc = Node.describe(node)

      assert is_map(desc)
      assert desc.id == "test-123"
      assert desc.name == "Test Node"
      assert desc.type == "mobile"
      assert desc.capabilities == ["camera"]
      assert is_binary(desc.last_seen_at) || is_nil(desc.last_seen_at)
    end
  end
end
