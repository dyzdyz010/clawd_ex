defmodule ClawdExWeb.NodesLive do
  @moduledoc """
  Nodes 管理页面 — 设备配对和管理
  """
  use ClawdExWeb, :live_view

  alias ClawdEx.Nodes.{Registry, Pairing}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(5_000, self(), :refresh)
    end

    socket =
      socket
      |> assign(:page_title, "Nodes")
      |> assign(:pair_code, nil)
      |> load_data()

    {:ok, socket}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, load_data(socket)}
  end

  @impl true
  def handle_event("generate_pair_code", _params, socket) do
    case Pairing.generate_pair_code() do
      {:ok, result} ->
        {:noreply, assign(socket, :pair_code, result)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to generate pair code")}
    end
  end

  @impl true
  def handle_event("approve_node", %{"id" => node_id}, socket) do
    case Pairing.approve_node(node_id) do
      {:ok, _result} ->
        socket =
          socket
          |> put_flash(:info, "Node approved")
          |> load_data()

        {:noreply, socket}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Node not found")}
    end
  end

  @impl true
  def handle_event("reject_node", %{"id" => node_id}, socket) do
    case Pairing.reject_node(node_id) do
      :ok ->
        socket =
          socket
          |> put_flash(:info, "Node rejected")
          |> load_data()

        {:noreply, socket}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Node not found")}
    end
  end

  @impl true
  def handle_event("revoke_node", %{"id" => node_id}, socket) do
    case Pairing.revoke_node(node_id) do
      :ok ->
        socket =
          socket
          |> put_flash(:info, "Node revoked")
          |> load_data()

        {:noreply, socket}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Node not found")}
    end
  end

  @impl true
  def handle_event("delete_node", %{"id" => node_id}, socket) do
    Registry.remove(node_id)

    socket =
      socket
      |> put_flash(:info, "Node deleted")
      |> load_data()

    {:noreply, socket}
  end

  defp load_data(socket) do
    nodes = Registry.list_nodes()
    pending = Pairing.list_pending()
    stats = Registry.stats()

    assign(socket,
      nodes: nodes,
      pending: pending,
      stats: stats
    )
  end
end
