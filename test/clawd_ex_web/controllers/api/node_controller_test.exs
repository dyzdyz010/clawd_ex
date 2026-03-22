defmodule ClawdExWeb.Api.NodeControllerTest do
  use ClawdExWeb.ConnCase, async: false

  alias ClawdEx.Nodes.{Pairing, Registry}

  setup %{conn: conn} do
    ensure_started(Registry)
    ensure_started(Pairing)

    Registry.reset()
    Pairing.reset()

    # The API auth plug skips auth when no token is configured (dev mode)
    conn = put_req_header(conn, "content-type", "application/json")
    {:ok, conn: conn}
  end

  defp ensure_started(module) do
    unless Process.whereis(module) do
      {:ok, _} = module.start_link(name: module)
    end
  end

  # Helper to set up a pending node via pairing flow
  defp create_pending_node do
    {:ok, %{code: code}} = Pairing.generate_pair_code()

    {:ok, result} =
      Pairing.verify_pair_code(code, %{
        name: "Test Device",
        type: "mobile",
        capabilities: ["camera"]
      })

    result
  end

  # Helper to set up an approved node
  defp create_approved_node do
    pending = create_pending_node()
    {:ok, approved} = Pairing.approve_node(pending.node_id)
    Map.merge(pending, approved)
  end

  # ============================================================================
  # POST /api/v1/nodes/generate_code
  # ============================================================================

  describe "POST /api/v1/nodes/generate_code" do
    test "generates a pair code", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/nodes/generate_code")

      assert %{"data" => data} = json_response(conn, 201)
      assert is_binary(data["code"])
      assert String.length(data["code"]) == 6
      assert data["ttl_seconds"] == 300
      assert is_binary(data["expires_at"])
    end
  end

  # ============================================================================
  # POST /api/v1/nodes/pair
  # ============================================================================

  describe "POST /api/v1/nodes/pair" do
    test "pairs device with valid code", %{conn: conn} do
      {:ok, %{code: code}} = Pairing.generate_pair_code()

      conn =
        post(conn, ~p"/api/v1/nodes/pair", %{
          code: code,
          name: "My iPhone",
          type: "mobile",
          capabilities: ["camera", "notifications"]
        })

      assert %{"data" => data} = json_response(conn, 201)
      assert is_binary(data["pair_token"])
      assert is_binary(data["node_id"])
      assert data["status"] == "pending"
    end

    test "rejects invalid code", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/nodes/pair", %{code: "999999"})

      assert %{"error" => error} = json_response(conn, 400)
      assert error["code"] == "invalid_code"
    end

    test "rejects missing code", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/nodes/pair", %{name: "Test"})

      assert %{"error" => _} = json_response(conn, 400)
    end

    test "rejects already-used code", %{conn: conn} do
      {:ok, %{code: code}} = Pairing.generate_pair_code()

      # First use
      post(conn, ~p"/api/v1/nodes/pair", %{code: code, name: "Device 1"})

      # Second use
      conn2 = post(conn, ~p"/api/v1/nodes/pair", %{code: code, name: "Device 2"})

      assert %{"error" => error} = json_response(conn2, 409)
      assert error["code"] == "code_already_used"
    end
  end

  # ============================================================================
  # GET /api/v1/nodes
  # ============================================================================

  describe "GET /api/v1/nodes" do
    test "lists approved nodes", %{conn: conn} do
      create_approved_node()

      conn = get(conn, ~p"/api/v1/nodes")

      assert %{"data" => data, "total" => total} = json_response(conn, 200)
      assert total >= 1
      assert is_list(data)
      assert Enum.any?(data, &(&1["name"] == "Test Device"))
    end

    test "returns empty list when no nodes", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/nodes")

      assert %{"data" => [], "total" => 0} = json_response(conn, 200)
    end
  end

  # ============================================================================
  # GET /api/v1/nodes/pending
  # ============================================================================

  describe "GET /api/v1/nodes/pending" do
    test "lists pending nodes", %{conn: conn} do
      create_pending_node()

      conn = get(conn, ~p"/api/v1/nodes/pending")

      assert %{"data" => data, "total" => total} = json_response(conn, 200)
      assert total >= 1
      assert Enum.any?(data, &(&1["name"] == "Test Device"))
    end
  end

  # ============================================================================
  # GET /api/v1/nodes/:id
  # ============================================================================

  describe "GET /api/v1/nodes/:id" do
    test "returns node details", %{conn: conn} do
      %{node_id: node_id} = create_approved_node()

      conn = get(conn, ~p"/api/v1/nodes/#{node_id}")

      assert %{"data" => data} = json_response(conn, 200)
      assert data["id"] == node_id
      assert data["name"] == "Test Device"
    end

    test "returns 404 for non-existent node", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/nodes/non-existent-id")

      assert json_response(conn, 404)
    end
  end

  # ============================================================================
  # POST /api/v1/nodes/:id/approve
  # ============================================================================

  describe "POST /api/v1/nodes/:id/approve" do
    test "approves pending node", %{conn: conn} do
      %{node_id: node_id} = create_pending_node()

      conn = post(conn, ~p"/api/v1/nodes/#{node_id}/approve")

      assert %{"data" => data} = json_response(conn, 200)
      assert data["node_id"] == node_id
      assert is_binary(data["node_token"])
      assert data["status"] == "connected"
    end

    test "returns 404 for non-existent node", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/nodes/non-existent/approve")

      assert json_response(conn, 404)
    end
  end

  # ============================================================================
  # POST /api/v1/nodes/:id/reject
  # ============================================================================

  describe "POST /api/v1/nodes/:id/reject" do
    test "rejects pending node", %{conn: conn} do
      %{node_id: node_id} = create_pending_node()

      conn = post(conn, ~p"/api/v1/nodes/#{node_id}/reject")

      assert %{"data" => data} = json_response(conn, 200)
      assert data["node_id"] == node_id
      assert data["status"] == "rejected"
    end

    test "returns 404 for non-existent node", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/nodes/non-existent/reject")

      assert json_response(conn, 404)
    end
  end

  # ============================================================================
  # DELETE /api/v1/nodes/:id
  # ============================================================================

  describe "DELETE /api/v1/nodes/:id" do
    test "revokes approved node", %{conn: conn} do
      %{node_id: node_id} = create_approved_node()

      conn = delete(conn, ~p"/api/v1/nodes/#{node_id}")

      assert %{"data" => data} = json_response(conn, 200)
      assert data["node_id"] == node_id
      assert data["status"] == "revoked"
    end

    test "returns 404 for non-existent node", %{conn: conn} do
      conn = delete(conn, ~p"/api/v1/nodes/non-existent")

      assert json_response(conn, 404)
    end
  end

  # ============================================================================
  # Full REST flow
  # ============================================================================

  describe "full REST pairing flow" do
    test "generate → pair → list pending → approve → list nodes → delete", %{conn: conn} do
      # 1. Generate pair code
      conn1 = post(conn, ~p"/api/v1/nodes/generate_code")
      %{"data" => %{"code" => code}} = json_response(conn1, 201)

      # 2. Device pairs
      conn2 =
        post(conn, ~p"/api/v1/nodes/pair", %{
          code: code,
          name: "Flow Test Device",
          type: "tablet"
        })

      %{"data" => %{"node_id" => node_id}} = json_response(conn2, 201)

      # 3. Check pending list
      conn3 = get(conn, ~p"/api/v1/nodes/pending")
      %{"data" => pending} = json_response(conn3, 200)
      assert Enum.any?(pending, &(&1["id"] == node_id))

      # 4. Approve
      conn4 = post(conn, ~p"/api/v1/nodes/#{node_id}/approve")
      %{"data" => %{"node_token" => _token}} = json_response(conn4, 200)

      # 5. Check nodes list
      conn5 = get(conn, ~p"/api/v1/nodes")
      %{"data" => nodes} = json_response(conn5, 200)
      assert Enum.any?(nodes, &(&1["id"] == node_id))

      # 6. No longer pending
      conn6 = get(conn, ~p"/api/v1/nodes/pending")
      %{"data" => pending2} = json_response(conn6, 200)
      refute Enum.any?(pending2, &(&1["id"] == node_id))

      # 7. Revoke
      conn7 = delete(conn, ~p"/api/v1/nodes/#{node_id}")
      assert json_response(conn7, 200)
    end
  end
end
