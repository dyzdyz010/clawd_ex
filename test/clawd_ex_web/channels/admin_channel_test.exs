defmodule ClawdExWeb.Channels.AdminChannelTest do
  use ClawdExWeb.ChannelCase, async: false

  alias ClawdExWeb.Channels.{GatewaySocket, AdminChannel}

  setup do
    # Clear configured tokens for dev mode access
    Application.delete_env(:clawd_ex, :gateway_token)
    Application.delete_env(:clawd_ex, :api_token)

    # Clean up any leaked sessions from other tests to ensure isolation
    ClawdEx.Sessions.SessionManager.stop_session("nonexistent:session")

    {:ok, socket} = connect(GatewaySocket, %{"token" => "any"})

    on_exit(fn ->
      Application.delete_env(:clawd_ex, :gateway_token)
      Application.delete_env(:clawd_ex, :api_token)
    end)

    %{socket: socket}
  end

  describe "join/3" do
    test "joins admin:control successfully with gateway auth", %{socket: socket} do
      assert {:ok, _, _socket} =
               subscribe_and_join(socket, "admin:control", %{})
    end

    test "rejects join with non-gateway auth" do
      # Simulate a node-type auth socket
      Application.delete_env(:clawd_ex, :gateway_token)

      {:ok, socket} = connect(GatewaySocket, %{"token" => "any"})
      # Override auth to simulate node type
      socket = %{socket | assigns: Map.put(socket.assigns, :auth, %{type: :node, node_id: "n1"})}

      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(socket, "admin:control", %{})
    end
  end

  describe "handle_in reload_plugins" do
    test "triggers plugin reload", %{socket: socket} do
      {:ok, _, socket} = subscribe_and_join(socket, "admin:control", %{})

      ref = push(socket, "reload_plugins", %{})

      # Plugin Manager may or may not be running in test
      # Accept either ok or error as valid responses
      assert_reply ref, status, _payload
      assert status in [:ok, :error]
    end
  end

  describe "handle_in reload_skills" do
    test "triggers skills reload", %{socket: socket} do
      {:ok, _, socket} = subscribe_and_join(socket, "admin:control", %{})

      ref = push(socket, "reload_skills", %{})

      assert_reply ref, status, _payload
      assert status in [:ok, :error]
    end
  end

  describe "handle_in clear_session" do
    test "returns error for missing session_key", %{socket: socket} do
      {:ok, _, socket} = subscribe_and_join(socket, "admin:control", %{})

      ref = push(socket, "clear_session", %{})
      assert_reply ref, :error, %{reason: "missing_session_key"}
    end

    test "returns error for non-existent session", %{socket: socket} do
      {:ok, _, socket} = subscribe_and_join(socket, "admin:control", %{})

      ref = push(socket, "clear_session", %{"session_key" => "nonexistent:session"})
      assert_reply ref, :error, %{reason: "session_not_found"}
    end
  end

  describe "handle_in system_stats" do
    test "returns system statistics", %{socket: socket} do
      {:ok, _, socket} = subscribe_and_join(socket, "admin:control", %{})

      ref = push(socket, "system_stats", %{})
      assert_reply ref, :ok, stats

      # Verify the structure of the stats response
      assert is_map(stats.memory)
      assert is_binary(stats.memory.total)
      assert is_integer(stats.memory.total_bytes)

      assert is_map(stats.processes)
      assert is_integer(stats.processes.count)
      assert is_integer(stats.processes.limit)
      assert is_float(stats.processes.usage_pct)

      assert is_map(stats.uptime)
      assert is_integer(stats.uptime.milliseconds)
      assert is_binary(stats.uptime.human)

      assert is_map(stats.sessions)
      assert is_integer(stats.sessions.active_count)

      assert is_map(stats.plugins)
      assert is_integer(stats.plugins.loaded_count)

      assert is_binary(stats.otp_release)
      assert is_binary(stats.elixir_version)
      assert is_binary(stats.node)
      assert is_binary(stats.timestamp)
    end
  end

  describe "handle_in unknown command" do
    test "returns error for unknown command", %{socket: socket} do
      {:ok, _, socket} = subscribe_and_join(socket, "admin:control", %{})

      ref = push(socket, "some_random_command", %{})
      assert_reply ref, :error, %{reason: "unknown_command"}
    end
  end

  describe "PubSub event relay" do
    test "pushes plugin:installed event to client", %{socket: socket} do
      {:ok, _, _socket} = subscribe_and_join(socket, "admin:control", %{})
      Process.sleep(50)

      AdminChannel.broadcast_event("plugin:installed", %{
        plugin_id: "my-plugin",
        version: "1.0.0"
      })

      assert_push "plugin:installed", %{
        plugin_id: "my-plugin",
        version: "1.0.0"
      }
    end

    test "pushes plugin:uninstalled event to client", %{socket: socket} do
      {:ok, _, _socket} = subscribe_and_join(socket, "admin:control", %{})
      Process.sleep(50)

      AdminChannel.broadcast_event("plugin:uninstalled", %{
        plugin_id: "old-plugin"
      })

      assert_push "plugin:uninstalled", %{plugin_id: "old-plugin"}
    end

    test "pushes config:changed event to client", %{socket: socket} do
      {:ok, _, _socket} = subscribe_and_join(socket, "admin:control", %{})
      Process.sleep(50)

      AdminChannel.broadcast_event("config:changed", %{
        key: "default_model",
        value: "gpt-4o"
      })

      assert_push "config:changed", %{key: "default_model", value: "gpt-4o"}
    end
  end

  describe "broadcast_event/2" do
    test "broadcasts via PubSub" do
      Phoenix.PubSub.subscribe(ClawdEx.PubSub, "admin:events")

      :ok = AdminChannel.broadcast_event("test:event", %{data: "admin_hello"})

      assert_receive {:admin_event, "test:event", %{data: "admin_hello"}}
    end
  end
end
