defmodule ClawdExWeb.NodesLiveTest do
  use ClawdExWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  alias ClawdEx.Nodes.{Registry, Pairing}

  setup do
    Registry.reset()
    Pairing.reset()
    :ok
  end

  test "renders nodes page with key elements", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/nodes")

    assert html =~ "Nodes"
    assert html =~ "Total Nodes"
    assert html =~ "Online"
    assert html =~ "Offline"
    assert html =~ "Pending"
    assert html =~ "No Paired Nodes"
    assert html =~ "Generate Pair Code"
    assert html =~ "Auto-refreshes every 5s"
  end

  test "generates and displays pair code", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/nodes")

    html = view |> render_click("generate_pair_code")

    assert html =~ "Pair Code"
    assert html =~ "Expires in"
  end

  test "approve and reject pending nodes", %{conn: conn} do
    {:ok, approve_node} =
      Registry.register_pending(%{name: "Approve Me", type: "mobile", capabilities: [], metadata: %{}})

    {:ok, reject_node} =
      Registry.register_pending(%{name: "Reject Me", type: "mobile", capabilities: [], metadata: %{}})

    {:ok, view, html} = live(conn, "/nodes")
    assert html =~ "Pending Approval"
    assert html =~ "Approve Me"
    assert html =~ "Reject Me"

    html = view |> render_click("approve_node", %{"id" => approve_node.id})
    assert html =~ "Node approved"

    html = view |> render_click("reject_node", %{"id" => reject_node.id})
    assert html =~ "Node rejected"
    refute html =~ "Reject Me"
  end

  test "revoke and delete paired nodes", %{conn: conn} do
    {:ok, node} =
      Registry.register_pending(%{name: "My MacBook", type: "desktop", capabilities: ["exec", "browser"], metadata: %{}})

    {:ok, _approved} = Registry.approve(node.id)

    {:ok, view, html} = live(conn, "/nodes")
    assert html =~ "My MacBook"

    html = view |> render_click("revoke_node", %{"id" => node.id})
    assert html =~ "Node revoked"
  end
end
