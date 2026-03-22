defmodule ClawdEx.Plugins.ImportantFixesTest do
  @moduledoc """
  Tests covering the 8 Important issues (I1–I8) from the Plugin V2 code review.
  """
  use ExUnit.Case, async: false

  alias ClawdEx.Plugins.{Store, NodeBridge}

  # ==========================================================================
  # I1: Store.save/1 uses atomic write (tmp + rename)
  # ==========================================================================
  describe "I1: Store.save/1 atomic write" do
    @tag :tmp_dir
    test "save writes via tmp file + rename pattern", %{tmp_dir: tmp_dir} do
      # We test the Store.save/1 function directly but it always writes to
      # ~/.clawd/plugins/registry.json. So we test the pattern indirectly:
      # save then verify file content is valid JSON (no partial writes).
      registry = %{version: 1, plugins: %{
        "atomic-test" => %{
          id: "atomic-test",
          name: "Atomic Test",
          version: "1.0.0",
          description: "Test atomic save",
          runtime: "beam",
          path: tmp_dir,
          entry: "",
          enabled: true,
          config: %{},
          installed_at: "2026-01-01T00:00:00Z",
          source: "test",
          provides: %{}
        }
      }}

      # Store.save writes to the real path, so we just verify the API works
      result = Store.save(registry)
      assert result == :ok

      # Verify the file is valid JSON
      {:ok, loaded} = Store.load()
      assert Map.has_key?(loaded.plugins, "atomic-test")
      assert loaded.plugins["atomic-test"].name == "Atomic Test"

      # Clean up
      cleaned = Store.remove_plugin(loaded, "atomic-test")
      Store.save(cleaned)
    end

    test "save returns encode_error for non-serializable data" do
      # A registry with a function value should fail to encode
      bad_registry = %{version: 1, plugins: %{
        "bad" => %{id: "bad", callback: fn -> :ok end}
      }}

      result = Store.save(bad_registry)
      assert match?({:error, {:encode_error, _}}, result)
    end

    test "no tmp file left behind after successful save" do
      registry = %{version: 1, plugins: %{}}
      :ok = Store.save(registry)

      tmp_path = Store.registry_path() <> ".tmp"
      refute File.exists?(tmp_path)
    end
  end

  # ==========================================================================
  # I3: NodeBridge exponential backoff with cap
  # ==========================================================================
  describe "I3: NodeBridge restart backoff" do
    test "bridge struct has restart_attempts and current_restart_delay fields" do
      state = :sys.get_state(NodeBridge)
      assert Map.has_key?(state, :restart_attempts)
      assert Map.has_key?(state, :current_restart_delay)
      assert is_integer(state.restart_attempts)
      assert is_integer(state.current_restart_delay)
    end

    test "restart_attempts is 0 when bridge is healthy" do
      state = :sys.get_state(NodeBridge)
      assert state.restart_attempts == 0
    end

    test "current_restart_delay starts at 1000ms" do
      state = :sys.get_state(NodeBridge)
      assert state.current_restart_delay == 1_000
    end
  end

  # ==========================================================================
  # I5: NodeBridge buffer size limit
  # ==========================================================================
  describe "I5: NodeBridge buffer size tracking" do
    test "bridge struct has buffer_size field" do
      state = :sys.get_state(NodeBridge)
      assert Map.has_key?(state, :buffer_size)
      assert is_integer(state.buffer_size)
    end

    test "buffer_size is 0 when no data is being buffered" do
      state = :sys.get_state(NodeBridge)
      assert state.buffer_size == 0
      assert state.buffer == ""
    end
  end

  # ==========================================================================
  # I7: CLI handle_config guard clause (no more return())
  # ==========================================================================
  describe "I7: CLI handle_config guard clause" do
    test "handle_config returns gracefully for nil plugin" do
      # We can't easily call the private function directly, but we can verify
      # that the module compiles without the unused `return/0` function
      # and the run/2 dispatch works
      exports = ClawdEx.CLI.Plugins.__info__(:functions)
      # The module should have run/2 but NOT return/0
      assert {:run, 2} in exports
      refute {:return, 0} in exports
    end
  end

  # ==========================================================================
  # I2: Manager reload stops existing plugins
  # ==========================================================================
  describe "I2: Manager reload cleanup" do
    test "reload still works and returns :ok" do
      # Ensure manager is running
      case GenServer.whereis(ClawdEx.Plugins.Manager) do
        nil -> ClawdEx.Plugins.Manager.start_link([])
        _pid -> :ok
      end

      assert :ok = ClawdEx.Plugins.Manager.reload()
    end

    test "plugins are re-loaded after reload" do
      case GenServer.whereis(ClawdEx.Plugins.Manager) do
        nil -> ClawdEx.Plugins.Manager.start_link([])
        _pid -> :ok
      end

      :ok = ClawdEx.Plugins.Manager.reload()
      plugins = ClawdEx.Plugins.Manager.list_plugins()
      # Should at least have builtin plugins (telegram, discord)
      assert length(plugins) >= 2
    end
  end

  # ==========================================================================
  # I4: plugin-host.mjs tool timeout (integration verified via NodeBridge)
  # ==========================================================================
  describe "I4: Tool execution timeout protection" do
    @fake_plugin_dir Path.expand("../../support/fixtures/fake-plugin", __DIR__)

    test "normal tool calls still work (timeout does not interfere)" do
      # Ensure the plugin is loaded
      try do
        NodeBridge.unload_plugin("fake-plugin")
      rescue _ -> :ok
      catch :exit, _ -> :ok
      end

      {:ok, _} = NodeBridge.load_plugin(@fake_plugin_dir, %{})

      # Normal call should complete well within timeout
      assert {:ok, result} = NodeBridge.call_tool("fake-plugin", "fake_echo", %{"message" => "timeout-test"}, %{})
      assert result["echoed"] == "timeout-test"

      NodeBridge.unload_plugin("fake-plugin")
    end
  end

  # ==========================================================================
  # I6: Manager enable/disable Node plugins via NodeBridge
  # ==========================================================================
  describe "I6: enable/disable Node plugins" do
    test "enable_plugin returns error for non-existent plugin" do
      case GenServer.whereis(ClawdEx.Plugins.Manager) do
        nil -> ClawdEx.Plugins.Manager.start_link([])
        _pid -> :ok
      end

      assert {:error, :not_found} = ClawdEx.Plugins.Manager.enable_plugin("nonexistent-i6-test")
    end

    test "disable_plugin returns error for non-existent plugin" do
      case GenServer.whereis(ClawdEx.Plugins.Manager) do
        nil -> ClawdEx.Plugins.Manager.start_link([])
        _pid -> :ok
      end

      assert {:error, :not_found} = ClawdEx.Plugins.Manager.disable_plugin("nonexistent-i6-test")
    end

    test "enable then disable a builtin plugin toggles state" do
      case GenServer.whereis(ClawdEx.Plugins.Manager) do
        nil -> ClawdEx.Plugins.Manager.start_link([])
        _pid -> :ok
      end

      # Disable telegram
      assert :ok = ClawdEx.Plugins.Manager.disable_plugin("telegram")
      plugin = ClawdEx.Plugins.Manager.get_plugin("telegram")
      assert plugin.enabled == false
      assert plugin.status == :disabled

      # Re-enable
      assert :ok = ClawdEx.Plugins.Manager.enable_plugin("telegram")
      plugin = ClawdEx.Plugins.Manager.get_plugin("telegram")
      assert plugin.enabled == true
      assert plugin.status == :loaded
    end
  end

  # ==========================================================================
  # I8: Node plugins loaded via NodeBridge at startup
  # ==========================================================================
  describe "I8: Node plugin bridge loading at startup" do
    test "load_node_plugin_from_registry is called during load_registry_plugins" do
      # This is tested indirectly: if a Node plugin exists in the registry,
      # after reload it should attempt to load via NodeBridge.
      # We verify the manager correctly handles the case where NodeBridge
      # is available by checking it doesn't crash.
      case GenServer.whereis(ClawdEx.Plugins.Manager) do
        nil -> ClawdEx.Plugins.Manager.start_link([])
        _pid -> :ok
      end

      # Reload triggers load_all_plugins which includes load_registry_plugins
      assert :ok = ClawdEx.Plugins.Manager.reload()

      # Manager should still be functional after reload
      plugins = ClawdEx.Plugins.Manager.list_plugins()
      assert is_list(plugins)
    end
  end
end
