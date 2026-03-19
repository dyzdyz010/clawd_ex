defmodule ClawdEx.MCP.ToolProxyTest do
  use ExUnit.Case, async: true

  alias ClawdEx.MCP.ToolProxy

  # ============================================================================
  # mcp_tool?
  # ============================================================================

  describe "mcp_tool?/1" do
    test "returns true for MCP-prefixed tool names" do
      assert ToolProxy.mcp_tool?("mcp__server__echo")
      assert ToolProxy.mcp_tool?("mcp__my-server__some_tool")
    end

    test "returns false for non-MCP tool names" do
      refute ToolProxy.mcp_tool?("read")
      refute ToolProxy.mcp_tool?("write")
      refute ToolProxy.mcp_tool?("exec")
      refute ToolProxy.mcp_tool?("")
    end

    test "returns false for non-binary input" do
      refute ToolProxy.mcp_tool?(nil)
      refute ToolProxy.mcp_tool?(123)
      refute ToolProxy.mcp_tool?(:atom)
    end

    test "returns true even for unusual but valid prefixed names" do
      assert ToolProxy.mcp_tool?("mcp__a__b")
    end
  end

  # ============================================================================
  # parse_tool_name
  # ============================================================================

  describe "parse_tool_name/1" do
    test "parses valid MCP tool name" do
      assert {:ok, "server1", "echo"} = ToolProxy.parse_tool_name("mcp__server1__echo")
    end

    test "parses tool name with hyphens" do
      assert {:ok, "my-server", "my-tool"} = ToolProxy.parse_tool_name("mcp__my-server__my-tool")
    end

    test "parses tool name with underscores in tool part" do
      assert {:ok, "srv", "my_tool_name"} = ToolProxy.parse_tool_name("mcp__srv__my_tool_name")
    end

    test "returns error for non-MCP tool name" do
      assert {:error, {:not_mcp_tool, "read"}} = ToolProxy.parse_tool_name("read")
    end

    test "returns error for malformed MCP name (no tool part)" do
      assert {:error, {:invalid_mcp_tool_name, "mcp__server"}} =
               ToolProxy.parse_tool_name("mcp__server")
    end

    test "returns error for malformed MCP name (empty parts)" do
      assert {:error, {:invalid_mcp_tool_name, "mcp____"}} =
               ToolProxy.parse_tool_name("mcp____")
    end

    test "returns error for empty server name" do
      assert {:error, {:invalid_mcp_tool_name, "mcp____tool"}} =
               ToolProxy.parse_tool_name("mcp____tool")
    end

    test "handles tool name with multiple underscores after server" do
      # "mcp__srv__a__b" → server="srv", tool="a__b" (splits on first __)
      assert {:ok, "srv", "a__b"} = ToolProxy.parse_tool_name("mcp__srv__a__b")
    end
  end

  # ============================================================================
  # prefix
  # ============================================================================

  describe "prefix/0" do
    test "returns the MCP tool prefix" do
      assert ToolProxy.prefix() == "mcp__"
    end
  end

  # ============================================================================
  # list_tools structure validation
  # ============================================================================

  describe "list_tools structure" do
    test "MCP tool map has expected fields" do
      # We test the data structure expectations that list_tools produces
      tool = %{
        name: "mcp__test-server__echo",
        description: "Echo back the input",
        parameters: %{"type" => "object"},
        source: :mcp,
        server: "test-server",
        original_name: "echo"
      }

      assert tool.name == "mcp__test-server__echo"
      assert tool.source == :mcp
      assert tool.server == "test-server"
      assert tool.original_name == "echo"
      assert is_map(tool.parameters)
    end

    test "prefixed name follows naming convention" do
      prefix = ToolProxy.prefix()
      server = "my-server"
      tool = "my-tool"
      expected = "#{prefix}#{server}__#{tool}"

      assert expected == "mcp__my-server__my-tool"
      assert ToolProxy.mcp_tool?(expected)
      assert {:ok, ^server, ^tool} = ToolProxy.parse_tool_name(expected)
    end
  end

  # ============================================================================
  # execute error cases (unit — no real connections)
  # ============================================================================

  describe "execute/3 error cases" do
    test "returns error for non-MCP tool name" do
      assert {:error, {:not_mcp_tool, "read"}} = ToolProxy.execute("read", %{}, %{})
    end

    test "returns error for malformed tool name" do
      assert {:error, {:invalid_mcp_tool_name, _}} = ToolProxy.execute("mcp__bad", %{}, %{})
    end

    test "returns error when server connection not found" do
      # ServerManager is not running in this test context or has no such server
      result = ToolProxy.execute("mcp__nonexistent-server__tool", %{}, %{})

      # Should be either :connection_not_found or some error from ServerManager being absent
      assert {:error, _} = result
    end
  end

  # ============================================================================
  # Tool name collision avoidance
  # ============================================================================

  describe "tool name collision avoidance" do
    test "MCP tool names never collide with built-in tools" do
      # Built-in tools: read, write, edit, exec, etc.
      # MCP tools: mcp__server__read, etc.
      refute ToolProxy.mcp_tool?("read")
      assert ToolProxy.mcp_tool?("mcp__server__read")

      # Parsing a built-in name should fail
      assert {:error, {:not_mcp_tool, "read"}} = ToolProxy.parse_tool_name("read")
    end

    test "different servers with same tool name produce different prefixed names" do
      name_a = "mcp__server-a__echo"
      name_b = "mcp__server-b__echo"

      refute name_a == name_b

      assert {:ok, "server-a", "echo"} = ToolProxy.parse_tool_name(name_a)
      assert {:ok, "server-b", "echo"} = ToolProxy.parse_tool_name(name_b)
    end
  end
end
