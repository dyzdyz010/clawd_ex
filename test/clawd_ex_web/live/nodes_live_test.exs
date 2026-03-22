defmodule ClawdExWeb.NodesLiveTest do
  use ClawdExWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  alias ClawdEx.Nodes.{Registry, Pairing}

  setup do
    # Reset state before each test
    Registry.reset()
    Pairing.reset()
    :ok
  end

  describe "mount" do
    test "renders nodes page", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/nodes")

      assert html =~ "Nodes"
    end

    test "displays stat cards", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/nodes")

      assert html =~ "Total Nodes"
      assert html =~ "Online"
      assert html =~ "Offline"
      assert html =~ "Pending"
    end

    test "shows empty state when no nodes", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/nodes")

      assert html =~ "No Paired Nodes"
      assert html =~ "Generate a pair code to connect a device"
    end

    test "shows generate pair code button", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/nodes")

      assert html =~ "Generate Pair Code"
    end

    test "shows auto-refresh note", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/nodes")

      assert html =~ "Auto-refreshes every 5s"
    end
  end

  describe "generate pair code" do
    test "generates and displays pair code", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/nodes")

      html = view |> render_click("generate_pair_code")

      assert html =~ "Pair Code"
      assert html =~ "Expires in"
    end
  end

  describe "with pending nodes" do
    test "shows pending approval section", %{conn: conn} do
      # Register a pending node
      {:ok, _node} =
        Registry.register_pending(%{
          name: "Test iPhone",
          type: "mobile",
          capabilities: [],
          metadata: %{}
        })

      {:ok, _view, html} = live(conn, "/nodes")

      assert html =~ "Pending Approval"
      assert html =~ "Test iPhone"
      assert html =~ "Approve"
      assert html =~ "Reject"
    end

    test "approve node moves it to paired list", %{conn: conn} do
      {:ok, node} =
        Registry.register_pending(%{
          name: "Test Device",
          type: "mobile",
          capabilities: [],
          metadata: %{}
        })

      {:ok, view, _html} = live(conn, "/nodes")

      html = view |> render_click("approve_node", %{"id" => node.id})

      assert html =~ "Node approved"
      assert html =~ "Test Device"
    end

    test "reject node removes it from pending", %{conn: conn} do
      {:ok, node} =
        Registry.register_pending(%{
          name: "Reject Me",
          type: "mobile",
          capabilities: [],
          metadata: %{}
        })

      {:ok, view, _html} = live(conn, "/nodes")

      html = view |> render_click("reject_node", %{"id" => node.id})

      assert html =~ "Node rejected"
      refute html =~ "Reject Me"
    end
  end

  describe "with paired nodes" do
    setup do
      {:ok, node} =
        Registry.register_pending(%{
          name: "My MacBook",
          type: "desktop",
          capabilities: ["exec", "browser"],
          metadata: %{}
        })

      # Approve to move to paired
      {:ok, _approved} = Registry.approve(node.id)

      %{node_id: node.id}
    end

    test "shows paired node in table", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/nodes")

      assert html =~ "My MacBook"
      assert html =~ "connected"
    end

    test "revoke node", %{conn: conn, node_id: node_id} do
      {:ok, view, _html} = live(conn, "/nodes")

      html = view |> render_click("revoke_node", %{"id" => node_id})

      assert html =~ "Node revoked"
    end

    test "delete node", %{conn: conn, node_id: node_id} do
      {:ok, view, _html} = live(conn, "/nodes")

      html = view |> render_click("delete_node", %{"id" => node_id})

      assert html =~ "Node deleted"
    end
  end
end
