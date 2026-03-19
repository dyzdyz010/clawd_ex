defmodule ClawdEx.MCP.ServerManagerTest do
  use ExUnit.Case, async: false

  alias ClawdEx.MCP.{ServerManager, Connection}

  @fake_server_path Path.expand("../../support/fake_mcp_server.exs", __DIR__)

  defp elixir_path do
    System.find_executable("elixir") || raise "elixir not found in PATH"
  end

  defp unique_name(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end

  defp server_config(extra_args \\ []) do
    %{
      "command" => elixir_path(),
      "args" => [@fake_server_path | extra_args],
      "env" => []
    }
  end

  defp wait_server_ready(manager, name, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    wait_server_ready_loop(manager, name, deadline)
  end

  defp wait_server_ready_loop(manager, name, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      {:error, :timeout}
    else
      case ServerManager.get_connection(name, manager) do
        {:ok, pid} ->
          case Connection.status(pid) do
            {:ok, %{status: :ready}} -> :ok
            _ ->
              Process.sleep(50)
              wait_server_ready_loop(manager, name, deadline)
          end

        _ ->
          Process.sleep(50)
          wait_server_ready_loop(manager, name, deadline)
      end
    end
  end

  setup do
    # Ensure MCP Registry is available for Connection via_name lookups
    case Registry.start_link(keys: :unique, name: ClawdEx.MCP.Registry) do
      {:ok, pid} -> on_exit(fn -> Process.exit(pid, :normal) end)
      {:error, {:already_started, _}} -> :ok
    end

    # Start a fresh ServerManager
    {:ok, manager} = ServerManager.start_link(name: :"sm_#{System.unique_integer([:positive])}")

    on_exit(fn ->
      if Process.alive?(manager), do: GenServer.stop(manager)
    end)

    %{manager: manager}
  end

  # ============================================================================
  # list_servers
  # ============================================================================

  describe "list_servers/1" do
    test "returns empty list when no servers", %{manager: manager} do
      assert [] = ServerManager.list_servers(manager)
    end

    test "returns all managed servers", %{manager: manager} do
      name1 = unique_name("list-a")
      name2 = unique_name("list-b")

      {:ok, _} = ServerManager.start_server(name1, server_config(), manager)
      {:ok, _} = ServerManager.start_server(name2, server_config(), manager)

      servers = ServerManager.list_servers(manager)
      server_names = Enum.map(servers, fn {name, _info} -> name end)

      assert name1 in server_names
      assert name2 in server_names
    end

    test "shows correct status for ready servers", %{manager: manager} do
      name = unique_name("list-ready")
      {:ok, _} = ServerManager.start_server(name, server_config(), manager)
      :ok = wait_server_ready(manager, name)

      servers = ServerManager.list_servers(manager)
      {^name, info} = Enum.find(servers, fn {n, _} -> n == name end)

      assert info.status == :ready
    end
  end

  # ============================================================================
  # start_server
  # ============================================================================

  describe "start_server/3" do
    test "starts a new server connection", %{manager: manager} do
      name = unique_name("start-test")

      assert {:ok, conn_pid} = ServerManager.start_server(name, server_config(), manager)
      assert is_pid(conn_pid)
      assert Process.alive?(conn_pid)
    end

    test "returns existing pid for duplicate name", %{manager: manager} do
      name = unique_name("dup-test")

      assert {:ok, pid1} = ServerManager.start_server(name, server_config(), manager)
      assert {:ok, pid2} = ServerManager.start_server(name, server_config(), manager)
      assert pid1 == pid2
    end

    test "returns error for missing command", %{manager: manager} do
      name = unique_name("no-cmd")
      assert {:error, :missing_command} = ServerManager.start_server(name, %{}, manager)
    end
  end

  # ============================================================================
  # stop_server
  # ============================================================================

  describe "stop_server/2" do
    test "stops an existing server", %{manager: manager} do
      name = unique_name("stop-test")
      {:ok, conn_pid} = ServerManager.start_server(name, server_config(), manager)
      :ok = wait_server_ready(manager, name)

      assert :ok = ServerManager.stop_server(name, manager)
      Process.sleep(100)
      refute Process.alive?(conn_pid)
    end

    test "returns error for non-existent server", %{manager: manager} do
      assert {:error, :not_found} = ServerManager.stop_server("nonexistent", manager)
    end

    test "server disappears from list after stop", %{manager: manager} do
      name = unique_name("stop-list")
      {:ok, _} = ServerManager.start_server(name, server_config(), manager)
      :ok = wait_server_ready(manager, name)

      ServerManager.stop_server(name, manager)
      Process.sleep(100)

      servers = ServerManager.list_servers(manager)
      server_names = Enum.map(servers, fn {n, _} -> n end)
      refute name in server_names
    end
  end

  # ============================================================================
  # get_connection
  # ============================================================================

  describe "get_connection/2" do
    test "returns connection pid for existing server", %{manager: manager} do
      name = unique_name("get-conn")
      {:ok, conn_pid} = ServerManager.start_server(name, server_config(), manager)

      assert {:ok, ^conn_pid} = ServerManager.get_connection(name, manager)
    end

    test "returns error for non-existent server", %{manager: manager} do
      assert {:error, :not_found} = ServerManager.get_connection("nope", manager)
    end

    test "returns error after server is stopped", %{manager: manager} do
      name = unique_name("dead-conn")
      {:ok, _conn_pid} = ServerManager.start_server(name, server_config(), manager)
      :ok = wait_server_ready(manager, name)

      # Stop the server cleanly
      :ok = ServerManager.stop_server(name, manager)
      Process.sleep(100)

      # Should no longer be found
      assert {:error, :not_found} = ServerManager.get_connection(name, manager)
    end
  end

  # ============================================================================
  # Config loading
  # ============================================================================

  describe "load_configs/0" do
    test "returns a map" do
      configs = ServerManager.load_configs()
      assert is_map(configs)
    end
  end

  # ============================================================================
  # reload_config
  # ============================================================================

  describe "reload_config/1" do
    test "stops servers removed from config", %{manager: manager} do
      name = unique_name("reload-stop")
      {:ok, conn_pid} = ServerManager.start_server(name, server_config(), manager)
      :ok = wait_server_ready(manager, name)

      # Set empty config in app env then reload
      prev = Application.get_env(:clawd_ex, :mcp_servers)
      Application.put_env(:clawd_ex, :mcp_servers, %{})

      assert :ok = ServerManager.reload_config(manager)

      Application.put_env(:clawd_ex, :mcp_servers, prev || %{})

      # The server should have been stopped
      Process.sleep(200)
      refute Process.alive?(conn_pid)

      servers = ServerManager.list_servers(manager)
      server_names = Enum.map(servers, fn {n, _} -> n end)
      refute name in server_names
    end

    test "starts new servers added to config", %{manager: manager} do
      name = unique_name("reload-add")

      prev = Application.get_env(:clawd_ex, :mcp_servers)

      # Add config and reload
      Application.put_env(:clawd_ex, :mcp_servers, %{
        name => server_config()
      })

      assert :ok = ServerManager.reload_config(manager)

      Application.put_env(:clawd_ex, :mcp_servers, prev || %{})

      # Wait for the new server to start
      :ok = wait_server_ready(manager, name)

      servers = ServerManager.list_servers(manager)
      server_names = Enum.map(servers, fn {n, _} -> n end)
      assert name in server_names
    end
  end

  # ============================================================================
  # Connection monitoring
  # ============================================================================

  describe "connection monitoring" do
    test "removes server when connection is stopped externally", %{manager: manager} do
      name = unique_name("monitor")
      {:ok, conn_pid} = ServerManager.start_server(name, server_config(), manager)
      :ok = wait_server_ready(manager, name)

      # Stop the connection externally (not via ServerManager)
      Connection.stop(conn_pid)
      # Wait for DOWN message to propagate to manager
      Process.sleep(300)

      # Server should be removed from manager
      servers = ServerManager.list_servers(manager)
      server_names = Enum.map(servers, fn {n, _} -> n end)
      refute name in server_names
    end
  end

  # ============================================================================
  # Init with config (auto-start via app env)
  # ============================================================================

  describe "init with config" do
    test "auto-starts servers from app env config on init" do
      name = unique_name("auto-start")

      prev = Application.get_env(:clawd_ex, :mcp_servers)
      Application.put_env(:clawd_ex, :mcp_servers, %{
        name => server_config()
      })

      # Ensure registry
      case Registry.start_link(keys: :unique, name: ClawdEx.MCP.Registry) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _}} -> :ok
      end

      {:ok, mgr} =
        ServerManager.start_link(
          name: :"sm_auto_#{System.unique_integer([:positive])}"
        )

      on_exit(fn ->
        Application.put_env(:clawd_ex, :mcp_servers, prev || %{})
        if Process.alive?(mgr), do: GenServer.stop(mgr)
      end)

      # Autostart is async (via send :autostart), give it time
      :ok = wait_server_ready(mgr, name)

      servers = ServerManager.list_servers(mgr)
      server_names = Enum.map(servers, fn {n, _} -> n end)
      assert name in server_names
    end
  end
end
