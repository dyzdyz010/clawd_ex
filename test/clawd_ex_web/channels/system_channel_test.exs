defmodule ClawdExWeb.Channels.SystemChannelTest do
  use ClawdExWeb.ChannelCase, async: false

  alias ClawdExWeb.Channels.GatewaySocket
  alias ClawdExWeb.Channels.SystemChannel

  setup do
    Application.delete_env(:clawd_ex, :gateway_token)
    Application.delete_env(:clawd_ex, :api_token)

    {:ok, socket} = connect(GatewaySocket, %{"token" => "any"})

    on_exit(fn ->
      Application.delete_env(:clawd_ex, :gateway_token)
      Application.delete_env(:clawd_ex, :api_token)
    end)

    %{socket: socket}
  end

  describe "join/3" do
    test "joins system:events successfully", %{socket: socket} do
      assert {:ok, _, _socket} =
               subscribe_and_join(socket, "system:events", %{})
    end
  end

  describe "PubSub event relay" do
    test "pushes session:created event to client", %{socket: socket} do
      {:ok, _, _socket} = subscribe_and_join(socket, "system:events", %{})

      # Send system event directly to channel process
      send(self(), :noop)
      Process.sleep(50)

      SystemChannel.broadcast_event("session:created", %{
        session_key: "test:session:1",
        agent: "architect"
      })

      assert_push "session:created", %{
        session_key: "test:session:1",
        agent: "architect"
      }
    end

    test "pushes session:ended event to client", %{socket: socket} do
      {:ok, _, _socket} = subscribe_and_join(socket, "system:events", %{})
      Process.sleep(50)

      SystemChannel.broadcast_event("session:ended", %{
        session_key: "test:session:1"
      })

      assert_push "session:ended", %{session_key: "test:session:1"}
    end

    test "pushes agent:status_changed event to client", %{socket: socket} do
      {:ok, _, _socket} = subscribe_and_join(socket, "system:events", %{})
      Process.sleep(50)

      SystemChannel.broadcast_event("agent:status_changed", %{
        agent_id: "architect",
        status: "idle"
      })

      assert_push "agent:status_changed", %{
        agent_id: "architect",
        status: "idle"
      }
    end

    test "pushes cron:executed event to client", %{socket: socket} do
      {:ok, _, _socket} = subscribe_and_join(socket, "system:events", %{})
      Process.sleep(50)

      SystemChannel.broadcast_event("cron:executed", %{
        job: "cleanup",
        result: "ok"
      })

      assert_push "cron:executed", %{job: "cleanup", result: "ok"}
    end
  end

  describe "broadcast_event/2" do
    test "broadcasts via PubSub" do
      Phoenix.PubSub.subscribe(ClawdEx.PubSub, "system:events")

      :ok = SystemChannel.broadcast_event("test:event", %{data: "hello"})

      assert_receive {:system_event, "test:event", %{data: "hello"}}
    end
  end
end
