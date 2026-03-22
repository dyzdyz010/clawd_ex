defmodule ClawdExWeb.Channels.NodeChannel do
  @moduledoc """
  设备 WebSocket 通道。

  处理已配对设备的实时通信，包括:
  - 心跳检测
  - 消息推送/接收
  - 能力更新
  - 工具执行请求/响应
  """
  use ClawdExWeb, :channel

  require Logger

  alias ClawdEx.Nodes.Registry

  @heartbeat_timeout_ms 90_000

  @impl true
  def join("node:" <> node_id, _params, socket) do
    auth = socket.assigns[:auth]

    cond do
      # 已配对设备: node_token 认证，且 node_id 匹配
      auth.type == :node && auth.node_id == node_id ->
        case Registry.get_node(node_id) do
          {:ok, node} when node.status in [:connected, :disconnected] ->
            # 更新状态为 connected
            Registry.update_status(node_id, :connected)
            send(self(), :after_join)
            schedule_heartbeat_check()

            {:ok, assign(socket, :node_id, node_id)}

          {:ok, _node} ->
            {:error, %{reason: "node_not_approved"}}

          {:error, :not_found} ->
            {:error, %{reason: "node_not_found"}}
        end

      # Gateway token 可以加入任意 node channel（管理员）
      auth.type == :gateway ->
        {:ok, assign(socket, :node_id, node_id)}

      true ->
        {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def handle_in("heartbeat", payload, socket) do
    node_id = socket.assigns.node_id
    Registry.touch(node_id)
    schedule_heartbeat_check()

    # 可以包含设备状态信息
    Logger.debug("Heartbeat from node #{node_id}: #{inspect(payload)}")

    {:reply, {:ok, %{timestamp: System.system_time(:millisecond)}}, socket}
  end

  @impl true
  def handle_in("capability:update", %{"capabilities" => capabilities}, socket) do
    node_id = socket.assigns.node_id

    case Registry.get_node(node_id) do
      {:ok, _node} ->
        # TODO: 更新 capabilities 在 Registry 中
        Logger.info("Node #{node_id} updated capabilities: #{inspect(capabilities)}")
        {:reply, :ok, socket}

      {:error, _} ->
        {:reply, {:error, %{reason: "node_not_found"}}, socket}
    end
  end

  @impl true
  def handle_in("tool:result", %{"request_id" => request_id, "result" => result}, socket) do
    node_id = socket.assigns.node_id
    Logger.info("Tool result from node #{node_id}, request: #{request_id}")

    # 广播工具执行结果
    Phoenix.PubSub.broadcast(
      ClawdEx.PubSub,
      "node:#{node_id}:tool_results",
      {:tool_result, request_id, result}
    )

    {:reply, :ok, socket}
  end

  @impl true
  def handle_in("event", payload, socket) do
    node_id = socket.assigns.node_id
    Logger.info("Event from node #{node_id}: #{inspect(payload)}")

    # 广播设备事件
    Phoenix.PubSub.broadcast(
      ClawdEx.PubSub,
      "node:#{node_id}:events",
      {:node_event, node_id, payload}
    )

    {:noreply, socket}
  end

  @impl true
  def handle_in(_event, _payload, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info(:after_join, socket) do
    node_id = socket.assigns.node_id

    # 广播节点连接事件
    Phoenix.PubSub.broadcast(
      ClawdEx.PubSub,
      "nodes:events",
      {:node_connected, node_id}
    )

    # 订阅节点指令 topic（用于服务端推送工具执行请求等）
    Phoenix.PubSub.subscribe(ClawdEx.PubSub, "node:#{node_id}:commands")

    {:noreply, socket}
  end

  @impl true
  def handle_info(:heartbeat_check, socket) do
    node_id = socket.assigns.node_id

    case Registry.get_node(node_id) do
      {:ok, node} when not is_nil(node.last_seen_at) ->
        now = DateTime.utc_now()
        diff_ms = DateTime.diff(now, node.last_seen_at, :millisecond)

        if diff_ms > @heartbeat_timeout_ms do
          Logger.warning("Node #{node_id} heartbeat timeout (#{diff_ms}ms)")
          Registry.update_status(node_id, :disconnected)

          Phoenix.PubSub.broadcast(
            ClawdEx.PubSub,
            "nodes:events",
            {:node_disconnected, node_id}
          )
        end

      _ ->
        :ok
    end

    schedule_heartbeat_check()
    {:noreply, socket}
  end

  @impl true
  def handle_info({:tool_execute, request_id, name, params}, socket) do
    push(socket, "tool:execute", %{
      request_id: request_id,
      name: name,
      params: params
    })

    {:noreply, socket}
  end

  @impl true
  def handle_info({:config_update, config}, socket) do
    push(socket, "config:update", %{config: config})
    {:noreply, socket}
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    if node_id = socket.assigns[:node_id] do
      # 只有 node 类型的连接才更新状态
      if socket.assigns[:auth] && socket.assigns.auth.type == :node do
        Registry.update_status(node_id, :disconnected)

        Phoenix.PubSub.broadcast(
          ClawdEx.PubSub,
          "nodes:events",
          {:node_disconnected, node_id}
        )
      end

      Logger.info("Node #{node_id} channel terminated")
    end

    :ok
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp schedule_heartbeat_check do
    Process.send_after(self(), :heartbeat_check, @heartbeat_timeout_ms)
  end
end
