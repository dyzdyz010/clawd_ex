defmodule ClawdEx.Tools.RegistryMCPIntegrationTest do
  use ExUnit.Case, async: false

  alias ClawdEx.Tools.Registry, as: ToolRegistry
  alias ClawdEx.MCP.{ToolProxy, ServerManager, Connection}

  @fake_server_path Path.expand("../../support/fake_mcp_server.exs", __DIR__)

  defp elixir_path do
    System.find_executable("elixir") || raise "elixir not found in PATH"
  end

  defp server_config do
    %{
      "command" => elixir_path(),
      "args" => [@fake_server_path],
      "env" => []
    }
  end

  defp unique_name(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}"
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

  # ============================================================================
  # MCP Tool identification
  # ============================================================================

  describe "MCP tool identification" do
    test "mcp_tool? correctly identifies MCP tools" do
      assert ToolProxy.mcp_tool?("mcp__server__tool")
      refute ToolProxy.mcp_tool?("read")
      refute ToolProxy.mcp_tool?("write")
      refute ToolProxy.mcp_tool?("exec")
    end
  end

  # ============================================================================
  # Built-in tools always available
  # ============================================================================

  describe "built-in tools" do
    test "list_tools always returns built-in tools" do
      tools = ToolRegistry.list_tools()
      tool_names = Enum.map(tools, & &1.name)

      assert "read" in tool_names
      assert "write" in tool_names
      assert "edit" in tool_names
      assert "exec" in tool_names
    end

    test "built-in tools do not have MCP prefix" do
      tools = ToolRegistry.list_tools()
      tool_names = Enum.map(tools, & &1.name)

      # No built-in tool should start with mcp__
      refute Enum.any?(tool_names, &String.starts_with?(&1, "mcp__"))
    end
  end

  # ============================================================================
  # Allow/Deny filtering
  # ============================================================================

  describe "allow/deny filtering" do
    test "wildcard deny blocks all tools" do
      tools = ToolRegistry.list_tools(deny: ["*"])
      assert tools == []
    end

    test "allow list restricts to only specified tools" do
      tools = ToolRegistry.list_tools(allow: ["read", "write"])
      tool_names = Enum.map(tools, & &1.name)

      assert "read" in tool_names
      assert "write" in tool_names
      refute "exec" in tool_names
    end

    test "deny list removes specific tools" do
      tools = ToolRegistry.list_tools(deny: ["exec"])
      tool_names = Enum.map(tools, & &1.name)

      assert "read" in tool_names
      refute "exec" in tool_names
    end

    test "deny takes precedence over allow" do
      tools = ToolRegistry.list_tools(allow: ["*"], deny: ["exec"])
      tool_names = Enum.map(tools, & &1.name)

      refute "exec" in tool_names
    end
  end

  # ============================================================================
  # ToolProxy name parsing integration
  # ============================================================================

  describe "ToolProxy integration" do
    test "parse_tool_name extracts server and tool" do
      assert {:ok, "my-server", "echo"} = ToolProxy.parse_tool_name("mcp__my-server__echo")
    end

    test "execute returns error for non-MCP names" do
      assert {:error, {:not_mcp_tool, "read"}} = ToolProxy.execute("read", %{}, %{})
    end

    test "MCP tool prefix is consistent" do
      prefix = ToolProxy.prefix()
      assert prefix == "mcp__"
      assert String.starts_with?("#{prefix}server__tool", prefix)
    end
  end

  # ============================================================================
  # Full end-to-end with fake MCP server
  # ============================================================================

  describe "end-to-end MCP tool execution" do
    setup do
      # Ensure MCP Registry
      case Elixir.Registry.start_link(keys: :unique, name: ClawdEx.MCP.Registry) do
        {:ok, pid} -> on_exit(fn -> Process.exit(pid, :normal) end)
        {:error, {:already_started, _}} -> :ok
      end

      name = unique_name("e2e")

      {:ok, manager} =
        ServerManager.start_link(
          name: :"sm_e2e_#{System.unique_integer([:positive])}"
        )

      {:ok, _conn_pid} = ServerManager.start_server(name, server_config(), manager)
      :ok = wait_server_ready(manager, name)

      on_exit(fn ->
        if Process.alive?(manager), do: GenServer.stop(manager)
      end)

      %{manager: manager, server_name: name}
    end

    test "can list tools from MCP server", %{manager: manager, server_name: name} do
      {:ok, conn_pid} = ServerManager.get_connection(name, manager)
      {:ok, tools} = Connection.list_tools(conn_pid)

      assert length(tools) == 2
      tool_names = Enum.map(tools, & &1["name"])
      assert "echo" in tool_names
      assert "add" in tool_names
    end

    test "tools have inputSchema", %{manager: manager, server_name: name} do
      {:ok, conn_pid} = ServerManager.get_connection(name, manager)
      {:ok, tools} = Connection.list_tools(conn_pid)

      echo_tool = Enum.find(tools, &(&1["name"] == "echo"))
      assert echo_tool["inputSchema"]["type"] == "object"
      assert echo_tool["inputSchema"]["properties"]["message"]["type"] == "string"
    end

    test "can call echo tool via connection", %{manager: manager, server_name: name} do
      {:ok, conn_pid} = ServerManager.get_connection(name, manager)
      {:ok, result} = Connection.call_tool(conn_pid, "echo", %{"message" => "integration test"})

      assert result["content"] == [
               %{"type" => "text", "text" => "integration test"}
             ]
    end

    test "can call add tool via connection", %{manager: manager, server_name: name} do
      {:ok, conn_pid} = ServerManager.get_connection(name, manager)
      {:ok, result} = Connection.call_tool(conn_pid, "add", %{"a" => 10, "b" => 20})

      content = result["content"]
      assert is_list(content)
      assert length(content) == 1
      assert hd(content)["type"] == "text"
      assert hd(content)["text"] == "30"
    end

    test "can ping the server", %{manager: manager, server_name: name} do
      {:ok, conn_pid} = ServerManager.get_connection(name, manager)
      assert :ok = Connection.ping(conn_pid)
    end
  end
end
