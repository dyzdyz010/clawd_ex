defmodule ClawdEx.Plugins.NodeBridgeTest do
  use ExUnit.Case, async: false

  alias ClawdEx.Plugins.NodeBridge

  @fake_plugin_dir Path.expand("../../support/fixtures/fake-plugin", __DIR__)

  setup do
    # Ensure the bridge is ready (started by application supervisor)
    # Wait briefly for port to be ready
    Process.sleep(200)

    # Clean up: unload our test plugin if leftover from previous test
    try do
      NodeBridge.unload_plugin("fake-plugin")
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end

    :ok
  end

  describe "status/0" do
    test "reports ready after start" do
      status = NodeBridge.status()
      assert status.status == :ready
      assert status.pending_count == 0
    end
  end

  describe "load_plugin/2" do
    test "loads a plugin from directory" do
      assert {:ok, result} = NodeBridge.load_plugin(@fake_plugin_dir, %{})
      assert result["ok"] == true
      assert result["pluginId"] == "fake-plugin"
      assert "fake_echo" in result["tools"]
    end

    test "returns error for non-existent plugin directory" do
      assert {:error, %{code: _, message: _}} =
               NodeBridge.load_plugin("/nonexistent/plugin/path", %{})
    end
  end

  describe "list_tools/1" do
    test "lists tools for a loaded plugin" do
      {:ok, _} = NodeBridge.load_plugin(@fake_plugin_dir, %{})

      tools = NodeBridge.list_tools("fake-plugin")
      assert is_list(tools)
      assert length(tools) == 1

      [tool] = tools
      assert tool["name"] == "fake_echo"
      assert tool["description"] =~ ~r/echo/i
      assert is_map(tool["parameters"])
    end

    test "returns empty list for unknown plugin" do
      tools = NodeBridge.list_tools("nonexistent-plugin")
      assert tools == []
    end
  end

  describe "call_tool/4" do
    test "calls a tool and returns result" do
      {:ok, _} = NodeBridge.load_plugin(@fake_plugin_dir, %{})

      assert {:ok, result} =
               NodeBridge.call_tool("fake-plugin", "fake_echo", %{"message" => "hello"}, %{})

      assert result["echoed"] == "hello"
    end

    test "returns error for unknown plugin" do
      assert {:error, _} =
               NodeBridge.call_tool("nonexistent", "some_tool", %{}, %{})
    end

    test "returns error for unknown tool" do
      {:ok, _} = NodeBridge.load_plugin(@fake_plugin_dir, %{})

      assert {:error, _} =
               NodeBridge.call_tool("fake-plugin", "nonexistent_tool", %{}, %{})
    end
  end

  describe "unload_plugin/1" do
    test "unloads a loaded plugin" do
      {:ok, _} = NodeBridge.load_plugin(@fake_plugin_dir, %{})
      assert :ok = NodeBridge.unload_plugin("fake-plugin")

      # After unload, list_tools should return empty
      tools = NodeBridge.list_tools("fake-plugin")
      assert tools == []
    end

    test "returns error for unknown plugin" do
      assert {:error, _} = NodeBridge.unload_plugin("nonexistent")
    end
  end
end
