defmodule ClawdExWeb.Channels.GatewaySocket do
  @moduledoc """
  Gateway 专用 WebSocket 入口。

  支持多种认证方式（按优先级顺序尝试）:
  1. node_token — 已配对设备连接
  2. pair_token — 配对过程中的临时连接
  3. gateway_token — 管理员/API 连接（含 dev mode 匿名访问）
  """
  use Phoenix.Socket

  channel "session:*", ClawdExWeb.Channels.SessionChannel
  channel "node:*", ClawdExWeb.Channels.NodeChannel
  channel "system:*", ClawdExWeb.Channels.SystemChannel
  channel "admin:*", ClawdExWeb.Channels.AdminChannel

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    # 1. 尝试验证为 node_token（已配对设备）
    case verify_node_token(token) do
      {:ok, node_id} ->
        {:ok, assign(socket, :auth, %{type: :node, node_id: node_id, token: token})}

      :skip ->
        # 2. 尝试验证为 pair_token（配对中）
        case verify_pair_token(token) do
          {:ok, node_id} ->
            {:ok, assign(socket, :auth, %{type: :pair, node_id: node_id})}

          :skip ->
            # 3. 尝试验证为 gateway_token（管理员）
            case verify_gateway_token(token) do
              {:ok, user_id} ->
                {:ok, assign(socket, :auth, %{type: :gateway, user_id: user_id})}

              :error ->
                :error
            end
        end
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket) do
    case socket.assigns[:auth] do
      %{type: :node, node_id: id} -> "node_socket:#{id}"
      %{type: :pair, node_id: id} -> "pair_socket:#{id}"
      %{type: :gateway, user_id: uid} -> "gateway:#{uid}"
      _ -> nil
    end
  end

  # ============================================================================
  # Token verification (private)
  # ============================================================================

  defp verify_node_token(token) do
    if pairing_available?() do
      case ClawdEx.Nodes.Pairing.verify_node_token(token) do
        {:ok, node_id} -> {:ok, node_id}
        {:error, _} -> :skip
      end
    else
      :skip
    end
  end

  defp verify_pair_token(token) do
    if pairing_available?() do
      case ClawdEx.Nodes.Pairing.verify_pair_token(token) do
        {:ok, node_id} -> {:ok, node_id}
        {:error, _} -> :skip
      end
    else
      :skip
    end
  end

  defp verify_gateway_token(token) do
    configured_token = get_configured_token()

    cond do
      # Dev mode: no token configured, allow anything
      is_nil(configured_token) || configured_token == "" ->
        {:ok, "anonymous"}

      # Token matches
      token == configured_token ->
        {:ok, "gateway"}

      true ->
        :error
    end
  end

  defp get_configured_token do
    Application.get_env(:clawd_ex, :gateway_token) ||
      Application.get_env(:clawd_ex, :api_token) ||
      System.get_env("CLAWD_API_TOKEN")
  end

  defp pairing_available? do
    Process.whereis(ClawdEx.Nodes.Pairing) != nil
  end
end
