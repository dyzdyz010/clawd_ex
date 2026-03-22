defmodule ClawdEx.Plugins.ManagerTestPlugin do
  @behaviour ClawdEx.Plugins.Plugin

  @impl true
  def id, do: "manager-test-plugin"

  @impl true
  def name, do: "manager-test-plugin"

  @impl true
  def version, do: "0.1.0"

  @impl true
  def description, do: "Mock plugin for manager tests"

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

defmodule ClawdEx.Plugins.ManagerTestPluginWithSpecs do
  @behaviour ClawdEx.Plugins.Plugin

  @impl true
  def id, do: "specs-test-plugin"

  @impl true
  def name, do: "specs-test-plugin"

  @impl true
  def version, do: "0.1.0"

  @impl true
  def description, do: "Mock plugin with tool specs"

  @impl true
  def plugin_type, do: :beam

  @impl true
  def capabilities, do: [:tools]

  @impl true
  def init(_config), do: {:ok, %{}}

  @impl true
  def tools, do: [ClawdEx.Plugins.ManagerTestMockTool]

  @impl true
  def providers, do: []
end

defmodule ClawdEx.Plugins.ManagerTestMockTool do
  def name, do: "mock_tool"
  def description, do: "A mock tool for testing"
  def parameters, do: %{}
end

defmodule ClawdEx.Plugins.ManagerTest do
  use ExUnit.Case, async: false

  alias ClawdEx.Plugins.{Manager, Plugin}

  @test_plugin ClawdEx.Plugins.ManagerTestPlugin
  @specs_plugin ClawdEx.Plugins.ManagerTestPluginWithSpecs

  setup do
    prev = Application.get_env(:clawd_ex, :plugins)

    on_exit(fn ->
      Application.put_env(:clawd_ex, :plugins, prev || [])

      case GenServer.whereis(Manager) do
        nil -> :ok
        _pid -> Manager.reload()
      end
    end)

    :ok
  end

  defp ensure_manager_with(plugin_config) do
    Application.put_env(:clawd_ex, :plugins, plugin_config)

    case GenServer.whereis(Manager) do
      nil ->
        {:ok, pid} = Manager.start_link([])
        pid

      _pid ->
        Manager.reload()
    end
  end

  # Builtin plugins (Telegram, Discord) are always loaded
  @builtin_count 2

  describe "list_plugins/0" do
    test "returns only builtin plugins when no extra plugins configured" do
      ensure_manager_with([])
      plugins = Manager.list_plugins()
      assert length(plugins) == @builtin_count
      ids = Enum.map(plugins, & &1.id) |> Enum.sort()
      assert ids == ["discord", "telegram"]
    end

    test "returns loaded plugins including builtins" do
      ensure_manager_with([{@test_plugin, %{}}])
      plugins = Manager.list_plugins()
      assert length(plugins) == @builtin_count + 1
      assert Enum.any?(plugins, &(&1.name == "manager-test-plugin"))
    end
  end

  describe "enable_plugin/1" do
    test "returns error for unknown plugin id" do
      ensure_manager_with([])
      assert {:error, :not_found} = Manager.enable_plugin("unknown-plugin-xyz")
    end

    test "enables a disabled plugin" do
      ensure_manager_with([{@test_plugin, %{}}])
      Manager.disable_plugin("manager-test-plugin")

      assert :ok = Manager.enable_plugin("manager-test-plugin")

      plugin = Manager.get_plugin("manager-test-plugin")
      assert plugin.enabled == true
      assert plugin.status == :loaded
    end
  end

  describe "disable_plugin/1" do
    test "returns error for unknown plugin id" do
      ensure_manager_with([])
      assert {:error, :not_found} = Manager.disable_plugin("unknown-plugin-xyz")
    end

    test "disables an enabled plugin" do
      ensure_manager_with([{@test_plugin, %{}}])

      assert :ok = Manager.disable_plugin("manager-test-plugin")

      plugin = Manager.get_plugin("manager-test-plugin")
      assert plugin.enabled == false
      assert plugin.status == :disabled
    end
  end

  describe "get_tools/0" do
    test "returns empty list when no plugins" do
      ensure_manager_with([])
      assert Manager.get_tools() == []
    end

    test "returns tools from loaded plugins" do
      ensure_manager_with([{@test_plugin, %{}}])
      tools = Manager.get_tools()
      assert tools == [:mock_tool_module]
    end

    test "excludes tools from disabled plugins" do
      ensure_manager_with([{@test_plugin, %{}}])
      Manager.disable_plugin("manager-test-plugin")
      assert Manager.get_tools() == []
    end
  end

  describe "get_tool_specs/0" do
    test "returns tool specs from loaded beam plugins" do
      ensure_manager_with([{@specs_plugin, %{}}])
      specs = Manager.get_tool_specs()

      assert length(specs) == 1
      [spec] = specs
      assert spec.name == "mock_tool"
      assert spec.plugin_id == "specs-test-plugin"
      assert spec.plugin_type == :beam
    end

    test "returns empty when no plugins" do
      ensure_manager_with([])
      assert Manager.get_tool_specs() == []
    end
  end

  describe "reload/0" do
    test "reloads all plugins from config" do
      ensure_manager_with([{@test_plugin, %{}}])
      assert length(Manager.list_plugins()) == @builtin_count + 1

      Application.put_env(:clawd_ex, :plugins, [])
      assert :ok = Manager.reload()
      # Only builtins remain
      assert length(Manager.list_plugins()) == @builtin_count
    end

    test "picks up newly configured plugins" do
      ensure_manager_with([])
      assert length(Manager.list_plugins()) == @builtin_count

      Application.put_env(:clawd_ex, :plugins, [{@test_plugin, %{}}])
      assert :ok = Manager.reload()
      assert length(Manager.list_plugins()) == @builtin_count + 1
    end
  end

  describe "get_plugin/1" do
    test "returns nil for unknown id" do
      ensure_manager_with([])
      assert Manager.get_plugin("nonexistent") == nil
    end

    test "returns plugin by id" do
      ensure_manager_with([{@test_plugin, %{}}])
      plugin = Manager.get_plugin("manager-test-plugin")
      assert %Plugin{} = plugin
      assert plugin.name == "manager-test-plugin"
    end
  end

  describe "get_providers/0" do
    test "returns empty when no plugins" do
      ensure_manager_with([])
      assert Manager.get_providers() == []
    end

    test "returns providers from loaded plugins" do
      ensure_manager_with([{@test_plugin, %{}}])
      providers = Manager.get_providers()
      assert providers == [%{name: "mock_provider"}]
    end

    test "excludes providers from disabled plugins" do
      ensure_manager_with([{@test_plugin, %{}}])
      Manager.disable_plugin("manager-test-plugin")
      assert Manager.get_providers() == []
    end
  end

  describe "get_channels/0" do
    test "returns builtin channels when no extra plugins" do
      ensure_manager_with([])
      channels = Manager.get_channels()
      assert length(channels) == @builtin_count
      ids = Enum.map(channels, & &1.id) |> Enum.sort()
      assert ids == ["discord", "telegram"]
    end
  end
end
