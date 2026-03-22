defmodule ClawdEx.Nodes.PairingTest do
  use ExUnit.Case, async: false

  alias ClawdEx.Nodes.{Pairing, Registry}

  setup do
    # Ensure services are running
    ensure_started(Registry)
    ensure_started(Pairing)

    # Clear state
    Registry.reset()
    Pairing.reset()

    :ok
  end

  defp ensure_started(module) do
    unless Process.whereis(module) do
      {:ok, _} = module.start_link(name: module)
    end
  end

  # ============================================================================
  # generate_pair_code/0
  # ============================================================================

  describe "generate_pair_code/0" do
    test "generates a 6-digit code" do
      {:ok, result} = Pairing.generate_pair_code()

      assert is_binary(result.code)
      assert String.length(result.code) == 6
      assert String.match?(result.code, ~r/^\d{6}$/)
    end

    test "includes expiration info" do
      {:ok, result} = Pairing.generate_pair_code()

      assert is_binary(result.expires_at)
      assert result.ttl_seconds == 300
    end

    test "generates unique codes" do
      codes =
        for _ <- 1..10 do
          {:ok, result} = Pairing.generate_pair_code()
          result.code
        end

      # At least some should be different (statistically near certain)
      assert length(Enum.uniq(codes)) > 1
    end
  end

  # ============================================================================
  # verify_pair_code/2
  # ============================================================================

  describe "verify_pair_code/2" do
    test "verifies valid code and creates pending node" do
      {:ok, %{code: code}} = Pairing.generate_pair_code()

      device_info = %{
        name: "Test iPhone",
        type: "mobile",
        capabilities: ["camera", "location"]
      }

      {:ok, result} = Pairing.verify_pair_code(code, device_info)

      assert is_binary(result.pair_token)
      assert is_binary(result.node_id)
      assert result.status == :pending

      # Should appear in pending list
      pending = Pairing.list_pending()
      assert Enum.any?(pending, &(&1.id == result.node_id))
      assert Enum.any?(pending, &(&1.name == "Test iPhone"))
    end

    test "rejects invalid code" do
      assert {:error, :invalid_code} = Pairing.verify_pair_code("000000", %{name: "Test"})
    end

    test "rejects already-used code" do
      {:ok, %{code: code}} = Pairing.generate_pair_code()

      {:ok, _} = Pairing.verify_pair_code(code, %{name: "Device 1"})
      assert {:error, :code_already_used} = Pairing.verify_pair_code(code, %{name: "Device 2"})
    end

    test "uses default values for missing device info" do
      {:ok, %{code: code}} = Pairing.generate_pair_code()

      {:ok, result} = Pairing.verify_pair_code(code, %{})

      # Should create node with defaults
      pending = Pairing.list_pending()
      node = Enum.find(pending, &(&1.id == result.node_id))
      assert node.name == "Unknown Device"
      assert node.type == "unknown"
    end
  end

  # ============================================================================
  # approve_node/1
  # ============================================================================

  describe "approve_node/1" do
    test "approves pending node and generates node_token" do
      {:ok, %{code: code}} = Pairing.generate_pair_code()
      {:ok, %{node_id: node_id}} = Pairing.verify_pair_code(code, %{name: "My Phone"})

      {:ok, result} = Pairing.approve_node(node_id)

      assert result.node_id == node_id
      assert is_binary(result.node_token)
      assert String.length(result.node_token) > 20
      assert result.name == "My Phone"
      assert result.status == :connected

      # Node should move from pending to approved
      pending = Pairing.list_pending()
      refute Enum.any?(pending, &(&1.id == node_id))

      nodes = Registry.list_nodes()
      assert Enum.any?(nodes, &(&1.id == node_id))
    end

    test "node_token can be verified" do
      {:ok, %{code: code}} = Pairing.generate_pair_code()
      {:ok, %{node_id: node_id}} = Pairing.verify_pair_code(code, %{name: "My Phone"})
      {:ok, %{node_token: token}} = Pairing.approve_node(node_id)

      assert {:ok, ^node_id} = Pairing.verify_node_token(token)
    end

    test "pair_token is invalidated after approval" do
      {:ok, %{code: code}} = Pairing.generate_pair_code()
      {:ok, %{node_id: node_id, pair_token: pair_token}} = Pairing.verify_pair_code(code, %{name: "My Phone"})

      {:ok, _} = Pairing.approve_node(node_id)

      assert {:error, :invalid_token} = Pairing.verify_pair_token(pair_token)
    end

    test "returns error for non-existent node" do
      assert {:error, :not_found} = Pairing.approve_node("non-existent-id")
    end
  end

  # ============================================================================
  # reject_node/1
  # ============================================================================

  describe "reject_node/1" do
    test "rejects pending node" do
      {:ok, %{code: code}} = Pairing.generate_pair_code()
      {:ok, %{node_id: node_id}} = Pairing.verify_pair_code(code, %{name: "Reject Me"})

      assert :ok = Pairing.reject_node(node_id)

      # Should be removed from pending
      pending = Pairing.list_pending()
      refute Enum.any?(pending, &(&1.id == node_id))
    end

    test "pair_token is invalidated after rejection" do
      {:ok, %{code: code}} = Pairing.generate_pair_code()
      {:ok, %{node_id: node_id, pair_token: pair_token}} = Pairing.verify_pair_code(code, %{name: "Reject Me"})

      :ok = Pairing.reject_node(node_id)

      assert {:error, :invalid_token} = Pairing.verify_pair_token(pair_token)
    end

    test "returns error for non-existent node" do
      assert {:error, :not_found} = Pairing.reject_node("non-existent-id")
    end
  end

  # ============================================================================
  # revoke_node/1
  # ============================================================================

  describe "revoke_node/1" do
    test "revokes approved node" do
      {:ok, %{code: code}} = Pairing.generate_pair_code()
      {:ok, %{node_id: node_id}} = Pairing.verify_pair_code(code, %{name: "Revoke Me"})
      {:ok, %{node_token: token}} = Pairing.approve_node(node_id)

      assert :ok = Pairing.revoke_node(node_id)

      # Node_token should be invalid
      assert {:error, :invalid_token} = Pairing.verify_node_token(token)

      # Node should be gone from active list
      nodes = Registry.list_nodes()
      refute Enum.any?(nodes, &(&1.id == node_id))
    end

    test "returns error for non-existent node" do
      assert {:error, :not_found} = Pairing.revoke_node("non-existent-id")
    end
  end

  # ============================================================================
  # Token verification
  # ============================================================================

  describe "verify_node_token/1" do
    test "returns error for invalid token" do
      assert {:error, :invalid_token} = Pairing.verify_node_token("bogus-token")
    end
  end

  describe "verify_pair_token/1" do
    test "verifies valid pair token" do
      {:ok, %{code: code}} = Pairing.generate_pair_code()
      {:ok, %{node_id: node_id, pair_token: pair_token}} = Pairing.verify_pair_code(code, %{name: "Test"})

      assert {:ok, ^node_id} = Pairing.verify_pair_token(pair_token)
    end

    test "returns error for invalid token" do
      assert {:error, :invalid_token} = Pairing.verify_pair_token("bogus-token")
    end
  end

  # ============================================================================
  # Full flow
  # ============================================================================

  describe "full pairing flow" do
    test "generate → verify → approve → use token" do
      # 1. Admin generates pair code
      {:ok, %{code: code}} = Pairing.generate_pair_code()

      # 2. Device submits code
      {:ok, %{pair_token: _pt, node_id: node_id}} =
        Pairing.verify_pair_code(code, %{
          name: "Kris's iPhone",
          type: "mobile",
          capabilities: ["camera", "notifications"]
        })

      # 3. Node appears in pending
      pending = Pairing.list_pending()
      assert Enum.any?(pending, &(&1.name == "Kris's iPhone"))

      # 4. Admin approves
      {:ok, %{node_token: node_token}} = Pairing.approve_node(node_id)

      # 5. Device uses node_token to authenticate
      assert {:ok, ^node_id} = Pairing.verify_node_token(node_token)

      # 6. Node is in approved list
      nodes = Registry.list_nodes()
      node = Enum.find(nodes, &(&1.id == node_id))
      assert node.name == "Kris's iPhone"
      assert node.status == :connected
    end

    test "generate → verify → reject" do
      {:ok, %{code: code}} = Pairing.generate_pair_code()
      {:ok, %{node_id: node_id}} = Pairing.verify_pair_code(code, %{name: "Bad Device"})

      :ok = Pairing.reject_node(node_id)

      pending = Pairing.list_pending()
      refute Enum.any?(pending, &(&1.id == node_id))
    end

    test "generate → verify → approve → revoke" do
      {:ok, %{code: code}} = Pairing.generate_pair_code()
      {:ok, %{node_id: node_id}} = Pairing.verify_pair_code(code, %{name: "Temp Device"})
      {:ok, %{node_token: token}} = Pairing.approve_node(node_id)

      # Token works
      assert {:ok, ^node_id} = Pairing.verify_node_token(token)

      # Revoke
      :ok = Pairing.revoke_node(node_id)

      # Token no longer works
      assert {:error, :invalid_token} = Pairing.verify_node_token(token)
    end
  end
end
