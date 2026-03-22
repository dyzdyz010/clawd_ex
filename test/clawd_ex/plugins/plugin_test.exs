defmodule ClawdEx.Plugins.PluginTest do
  use ExUnit.Case, async: false

  alias ClawdEx.Plugins.{Plugin, Manager}

  describe "Plugin struct" do
    test "creates with default values" do
      plugin = %Plugin{}
      assert plugin.enabled == true
      assert plugin.config == %{}
      assert plugin.name == nil
      assert plugin.version == nil
      assert plugin.description == nil
      assert plugin.module == nil
    end

    test "creates with custom values" do
      plugin = %Plugin{
        name: "test-plugin",
        version: "1.0.0",
        description: "A test plugin",
        module: SomeModule,
        enabled: false,
        config: %{key: "value"}
      }

      assert plugin.name == "test-plugin"
      assert plugin.version == "1.0.0"
      assert plugin.description == "A test plugin"
      assert plugin.module == SomeModule
      assert plugin.enabled == false
      assert plugin.config == %{key: "value"}
    end

    test "enabled defaults to true" do
      plugin = %Plugin{name: "x"}
      assert plugin.enabled == true
    end

    test "config defaults to empty map" do
      plugin = %Plugin{name: "x"}
      assert plugin.config == %{}
    end
  end

  # Builtin plugins (Telegram, Discord) are always loaded
  @builtin_count 2

  describe "Manager" do
    setup do
      # Ensure no plugins configured for clean tests
      prev = Application.get_env(:clawd_ex, :plugins)
      Application.put_env(:clawd_ex, :plugins, [])

      # Start manager (or use existing)
      case GenServer.whereis(Manager) do
        nil ->
          {:ok, pid} = Manager.start_link([])
          on_exit(fn ->
            Application.put_env(:clawd_ex, :plugins, prev || [])
            if Process.alive?(pid), do: GenServer.stop(pid)
          end)
          %{pid: pid}

        pid ->
          # Reload with empty plugin list
          Manager.reload()
          on_exit(fn ->
            Application.put_env(:clawd_ex, :plugins, prev || [])
            Manager.reload()
          end)
          %{pid: pid}
      end
    end

    test "list_plugins returns only builtins when no extra plugins configured" do
      result = Manager.list_plugins()
      assert length(result) == @builtin_count
    end

    test "get_tools returns empty list when no extra plugins configured" do
      result = Manager.get_tools()
      assert result == []
    end

    test "get_providers returns empty list when no extra plugins configured" do
      result = Manager.get_providers()
      assert result == []
    end

    test "enable_plugin for non-existent plugin returns error" do
      result = Manager.enable_plugin("nonexistent-plugin")
      assert result == {:error, :not_found}
    end

    test "disable_plugin for non-existent plugin returns error" do
      result = Manager.disable_plugin("nonexistent-plugin")
      assert result == {:error, :not_found}
    end

    test "reload resets state to builtins only" do
      assert :ok = Manager.reload()
      # After reload with empty config, should have only builtins
      assert length(Manager.list_plugins()) == @builtin_count
    end
  end

  describe "Manager with mock plugin" do
    setup do
      prev = Application.get_env(:clawd_ex, :plugins)
      Application.put_env(:clawd_ex, :plugins, [{ClawdEx.Plugins.TestPlugin, %{}}])

      case GenServer.whereis(Manager) do
        nil ->
          {:ok, pid} = Manager.start_link([])
          on_exit(fn ->
            Application.put_env(:clawd_ex, :plugins, prev || [])
            if Process.alive?(pid), do: GenServer.stop(pid)
          end)
          %{pid: pid}

        pid ->
          Manager.reload()
          on_exit(fn ->
            Application.put_env(:clawd_ex, :plugins, prev || [])
            Manager.reload()
          end)
          %{pid: pid}
      end
    end

    test "loads a plugin and lists it" do
      plugins = Manager.list_plugins()
      assert length(plugins) == @builtin_count + 1
      assert Enum.any?(plugins, &(&1.name == "test-plugin" && &1.version == "0.1.0"))
    end

    test "get_tools returns tools from plugin" do
      tools = Manager.get_tools()
      assert tools == [:mock_tool_module]
    end

    test "get_providers returns providers from plugin" do
      providers = Manager.get_providers()
      assert providers == [%{name: "mock_provider"}]
    end

    test "disable_plugin disables it" do
      assert :ok = Manager.disable_plugin("test-plugin")

      plugin = Manager.get_plugin("test-plugin")
      refute plugin.enabled

      # Disabled plugins should not contribute tools
      assert Manager.get_tools() == []
      assert Manager.get_providers() == []
    end

    test "enable_plugin re-enables it" do
      Manager.disable_plugin("test-plugin")
      assert :ok = Manager.enable_plugin("test-plugin")

      plugin = Manager.get_plugin("test-plugin")
      assert plugin.enabled
      assert Manager.get_tools() == [:mock_tool_module]
    end
  end
end

# Mock plugin module for testing
defmodule ClawdEx.Plugins.TestPlugin do
  @behaviour ClawdEx.Plugins.Plugin

  @impl true
  def id, do: "test-plugin"

  @impl true
  def name, do: "test-plugin"

  @impl true
  def version, do: "0.1.0"

  @impl true
  def description, do: "A test plugin for unit tests"

  @impl true
  def plugin_type, do: :beam

  @impl true
  def capabilities, do: [:tools, :providers]

  @impl true
  def init(_config), do: {:ok, %{}}

  @impl true
  def tools, do: [:mock_tool_module]

  @impl true
  def providers, do: [%{name: "mock_provider"}]
end
