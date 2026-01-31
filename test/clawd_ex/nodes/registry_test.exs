defmodule ClawdEx.Nodes.RegistryTest do
  use ExUnit.Case, async: false

  alias ClawdEx.Nodes.Registry

  # Start a fresh Registry for each test using start_supervised!
  # This ensures proper isolation and cleanup

  setup do
    # Ensure Registry is running (start if not already)
    unless Process.whereis(Registry) do
      {:ok, _} = Registry.start_link(name: Registry)
    end
    
    # Clear the registry state for test isolation
    # We call reset which clears all nodes
    Registry.reset()

    :ok
  end

  describe "register_pending/1" do
    test "registers a new pending node" do
      {:ok, node} = Registry.register_pending(%{
        name: "Test iPhone",
        type: "mobile",
        capabilities: ["camera", "location"]
      })

      assert node.id != nil
      assert node.name == "Test iPhone"
      assert node.status == :pending

      # Should appear in pending list
      pending = Registry.list_pending()
      assert Enum.any?(pending, &(&1.id == node.id))
    end
  end

  describe "approve/1" do
    test "approves a pending node" do
      {:ok, node} = Registry.register_pending(%{name: "Pending Node"})

      {:ok, approved} = Registry.approve(node.id)

      assert approved.status == :connected
      assert approved.paired_at != nil

      # Should move from pending to nodes
      pending = Registry.list_pending()
      nodes = Registry.list_nodes()

      refute Enum.any?(pending, &(&1.id == node.id))
      assert Enum.any?(nodes, &(&1.id == node.id))
    end

    test "returns error for non-existent node" do
      assert {:error, :not_found} = Registry.approve("non-existent-id")
    end
  end

  describe "reject/1" do
    test "rejects a pending node" do
      {:ok, node} = Registry.register_pending(%{name: "Pending Node"})

      :ok = Registry.reject(node.id)

      # Should be removed from pending
      pending = Registry.list_pending()
      refute Enum.any?(pending, &(&1.id == node.id))
    end

    test "returns error for non-existent node" do
      assert {:error, :not_found} = Registry.reject("non-existent-id")
    end
  end

  describe "list_nodes/0" do
    test "returns all connected nodes" do
      {:ok, node1} = Registry.register_pending(%{name: "Node 1"})
      {:ok, node2} = Registry.register_pending(%{name: "Node 2"})

      Registry.approve(node1.id)
      Registry.approve(node2.id)

      nodes = Registry.list_nodes()

      assert length(nodes) >= 2
      assert Enum.any?(nodes, &(&1.name == "Node 1"))
      assert Enum.any?(nodes, &(&1.name == "Node 2"))
    end
  end

  describe "get_node/1" do
    test "returns node by ID" do
      {:ok, node} = Registry.register_pending(%{name: "Test Node"})
      Registry.approve(node.id)

      {:ok, found} = Registry.get_node(node.id)
      assert found.name == "Test Node"
    end

    test "returns error for non-existent node" do
      assert {:error, :not_found} = Registry.get_node("non-existent-id")
    end
  end

  describe "find_by_name/1" do
    test "finds node by exact name" do
      {:ok, node} = Registry.register_pending(%{name: "My iPhone"})
      Registry.approve(node.id)

      {:ok, found} = Registry.find_by_name("My iPhone")
      assert found.id == node.id
    end

    test "finds node by partial name (case insensitive)" do
      {:ok, node} = Registry.register_pending(%{name: "My iPhone 15 Pro"})
      Registry.approve(node.id)

      {:ok, found} = Registry.find_by_name("iphone")
      assert found.id == node.id
    end

    test "returns error for non-existent name" do
      assert {:error, :not_found} = Registry.find_by_name("Non Existent")
    end
  end

  describe "update_status/2" do
    test "updates node status" do
      {:ok, node} = Registry.register_pending(%{name: "Test Node"})
      Registry.approve(node.id)

      {:ok, updated} = Registry.update_status(node.id, :disconnected)
      assert updated.status == :disconnected
    end
  end

  describe "stats/0" do
    test "returns correct statistics" do
      # Add some nodes
      {:ok, node1} = Registry.register_pending(%{name: "Node 1"})
      {:ok, _node2} = Registry.register_pending(%{name: "Node 2"})
      Registry.approve(node1.id)

      stats = Registry.stats()

      assert stats.total >= 1
      assert stats.pending >= 1
      assert is_integer(stats.connected)
      assert is_integer(stats.disconnected)
    end
  end
end
