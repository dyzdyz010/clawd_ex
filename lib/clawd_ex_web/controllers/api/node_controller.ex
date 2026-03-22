defmodule ClawdExWeb.Api.NodeController do
  @moduledoc """
  Node 管理 REST API controller.

  处理设备配对、审批、撤销等操作。
  """
  use ClawdExWeb, :controller

  alias ClawdEx.Nodes.{Pairing, Registry}

  action_fallback ClawdExWeb.Api.FallbackController

  @doc """
  POST /api/v1/nodes/pair — 提交配对码 + 设备信息，返回 pair_token
  """
  def pair(conn, %{"code" => code} = params) do
    device_info = %{
      name: params["name"] || "Unknown Device",
      type: params["type"] || "unknown",
      capabilities: params["capabilities"] || [],
      metadata: params["metadata"] || %{}
    }

    case Pairing.verify_pair_code(code, device_info) do
      {:ok, result} ->
        conn
        |> put_status(:created)
        |> json(%{
          data: %{
            pair_token: result.pair_token,
            node_id: result.node_id,
            status: "pending"
          }
        })

      {:error, :invalid_code} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: %{code: "invalid_code", message: "Invalid pair code"}})

      {:error, :code_expired} ->
        conn
        |> put_status(:gone)
        |> json(%{error: %{code: "code_expired", message: "Pair code has expired"}})

      {:error, :code_already_used} ->
        conn
        |> put_status(:conflict)
        |> json(%{error: %{code: "code_already_used", message: "Pair code already used"}})
    end
  end

  def pair(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: %{code: "bad_request", message: "Missing required field: code"}})
  end

  @doc """
  GET /api/v1/nodes — 列出所有已配对设备
  """
  def index(conn, _params) do
    nodes = Registry.list_nodes()

    json(conn, %{
      data: Enum.map(nodes, &ClawdEx.Nodes.Node.describe/1),
      total: length(nodes)
    })
  end

  @doc """
  GET /api/v1/nodes/pending — 列出待配对设备
  """
  def pending(conn, _params) do
    pending = Pairing.list_pending()

    json(conn, %{
      data: Enum.map(pending, &ClawdEx.Nodes.Node.describe/1),
      total: length(pending)
    })
  end

  @doc """
  GET /api/v1/nodes/:id — 获取节点详情
  """
  def show(conn, %{"id" => id}) do
    case Registry.get_node(id) do
      {:ok, node} ->
        json(conn, %{data: ClawdEx.Nodes.Node.describe(node)})

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  POST /api/v1/nodes/:id/approve — 确认配对
  """
  def approve(conn, %{"id" => id}) do
    case Pairing.approve_node(id) do
      {:ok, result} ->
        json(conn, %{
          data: %{
            node_id: result.node_id,
            node_token: result.node_token,
            name: result.name,
            status: "connected"
          }
        })

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  POST /api/v1/nodes/:id/reject — 拒绝配对
  """
  def reject(conn, %{"id" => id}) do
    case Pairing.reject_node(id) do
      :ok ->
        json(conn, %{data: %{node_id: id, status: "rejected"}})

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  DELETE /api/v1/nodes/:id — 撤销设备
  """
  def delete(conn, %{"id" => id}) do
    case Pairing.revoke_node(id) do
      :ok ->
        conn
        |> put_status(:ok)
        |> json(%{data: %{node_id: id, status: "revoked"}})

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  POST /api/v1/nodes/generate_code — 生成配对码（管理员用）
  """
  def generate_code(conn, _params) do
    {:ok, result} = Pairing.generate_pair_code()

    conn
    |> put_status(:created)
    |> json(%{data: result})
  end
end
