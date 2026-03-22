defmodule ClawdExWeb.Channels.SystemChannel do
  @moduledoc """
  系统事件广播 Channel。

  Topic: "system:events"

  广播全局事件:
    - session:created / session:ended
    - agent:status_changed
    - cron:executed
    - broadcast (general system messages)

  事件来源: 通过 PubSub "system:events" topic 订阅。
  """
  use Phoenix.Channel

  require Logger

  @pubsub_topic "system:events"

  @impl true
  def join("system:events", _params, socket) do
    Phoenix.PubSub.subscribe(ClawdEx.PubSub, @pubsub_topic)
    {:ok, socket}
  end

  # --- PubSub relay → push to clients ---

  @impl true
  def handle_info({:system_event, event_type, payload}, socket) do
    push(socket, event_type, payload)
    {:noreply, socket}
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # --- Helpers for broadcasting system events (call from anywhere) ---

  @doc """
  Broadcast a system event to all connected system:events clients.

  ## Examples

      SystemChannel.broadcast_event("session:created", %{session_key: "abc"})
      SystemChannel.broadcast_event("agent:status_changed", %{agent_id: "arch", status: "idle"})
  """
  @spec broadcast_event(String.t(), map()) :: :ok | {:error, term()}
  def broadcast_event(event_type, payload) when is_binary(event_type) and is_map(payload) do
    Phoenix.PubSub.broadcast(
      ClawdEx.PubSub,
      @pubsub_topic,
      {:system_event, event_type, payload}
    )
  end
end
