defmodule ClawdEx.Plugins.BuiltinPluginsTest do
  @moduledoc """
  Integration tests for builtin Telegram & Discord channel plugins.

  Verifies that the builtin plugins implement the Plugin behaviour correctly,
  are loaded by the Plugin Manager, and register their channels with the
  Channel Registry.
  """
  use ExUnit.Case, async: false

  alias ClawdEx.Plugins.{Manager, Plugin}
  alias ClawdEx.Plugins.Builtin.{TelegramPlugin, DiscordPlugin}
  alias ClawdEx.Channels.Registry, as: ChannelRegistry

  # ============================================================================
  # TelegramPlugin behaviour
  # ============================================================================

  describe "TelegramPlugin" do
    test "implements Plugin behaviour" do
      assert TelegramPlugin.id() == "telegram"
      assert TelegramPlugin.name() == "Telegram"
      assert TelegramPlugin.version() == "1.0.0"
      assert TelegramPlugin.description() == "Built-in Telegram channel"
      assert TelegramPlugin.plugin_type() == :beam
      assert TelegramPlugin.capabilities() == [:channels]
    end

    test "init returns ok" do
      assert {:ok, _state} = TelegramPlugin.init(%{})
    end

    test "channels returns correct spec" do
      [channel] = TelegramPlugin.channels()
      assert channel.id == "telegram"
      assert channel.label == "Telegram"
      assert channel.module == ClawdEx.Channels.Telegram
      assert channel.source == :builtin
    end
  end

  # ============================================================================
  # DiscordPlugin behaviour
  # ============================================================================

  describe "DiscordPlugin" do
    test "implements Plugin behaviour" do
      assert DiscordPlugin.id() == "discord"
      assert DiscordPlugin.name() == "Discord"
      assert DiscordPlugin.version() == "1.0.0"
      assert DiscordPlugin.description() == "Built-in Discord channel"
      assert DiscordPlugin.plugin_type() == :beam
      assert DiscordPlugin.capabilities() == [:channels]
    end

    test "init returns ok" do
      assert {:ok, _state} = DiscordPlugin.init(%{})
    end

    test "channels returns correct spec" do
      [channel] = DiscordPlugin.channels()
      assert channel.id == "discord"
      assert channel.label == "Discord"
      assert channel.module == ClawdEx.Channels.Discord
      assert channel.source == :builtin
    end
  end

  # ============================================================================
  # Manager integration
  # ============================================================================

  describe "Manager loads builtin plugins" do
    setup do
      prev = Application.get_env(:clawd_ex, :plugins)
      Application.put_env(:clawd_ex, :plugins, [])

      case GenServer.whereis(Manager) do
        nil ->
          {:ok, _pid} = Manager.start_link([])
          :ok

        _pid ->
          Manager.reload()
      end

      on_exit(fn ->
        Application.put_env(:clawd_ex, :plugins, prev || [])

        case GenServer.whereis(Manager) do
          nil -> :ok
          _pid -> Manager.reload()
        end
      end)

      :ok
    end

    test "telegram plugin is loaded" do
      plugin = Manager.get_plugin("telegram")
      assert %Plugin{} = plugin
      assert plugin.id == "telegram"
      assert plugin.name == "Telegram"
      assert plugin.plugin_type == :beam
      assert plugin.enabled == true
      assert :channels in plugin.capabilities
    end

    test "discord plugin is loaded" do
      plugin = Manager.get_plugin("discord")
      assert %Plugin{} = plugin
      assert plugin.id == "discord"
      assert plugin.name == "Discord"
      assert plugin.plugin_type == :beam
      assert plugin.enabled == true
      assert :channels in plugin.capabilities
    end

    test "get_channels returns builtin channels" do
      channels = Manager.get_channels()
      ids = Enum.map(channels, & &1.id) |> Enum.sort()
      assert "telegram" in ids
      assert "discord" in ids
    end
  end

  # ============================================================================
  # Channel Registry integration
  # ============================================================================

  describe "Channel Registry integration" do
    setup do
      prev = Application.get_env(:clawd_ex, :plugins)
      Application.put_env(:clawd_ex, :plugins, [])

      case GenServer.whereis(Manager) do
        nil ->
          {:ok, _pid} = Manager.start_link([])
          :ok

        _pid ->
          Manager.reload()
      end

      on_exit(fn ->
        Application.put_env(:clawd_ex, :plugins, prev || [])

        case GenServer.whereis(Manager) do
          nil -> :ok
          _pid -> Manager.reload()
        end
      end)

      :ok
    end

    test "telegram channel is registered in the registry" do
      entry = ChannelRegistry.get("telegram")
      assert entry != nil
      assert entry.id == "telegram"
      assert entry.module == ClawdEx.Channels.Telegram
      assert entry.label == "Telegram"
      assert entry.source == :builtin
    end

    test "discord channel is registered in the registry" do
      entry = ChannelRegistry.get("discord")
      assert entry != nil
      assert entry.id == "discord"
      assert entry.module == ClawdEx.Channels.Discord
      assert entry.label == "Discord"
      assert entry.source == :builtin
    end

    test "ChannelDispatcher can resolve channels via registry" do
      # Verify that ChannelDispatcher's send_to_channel path works
      # through the registry (it uses ChannelRegistry.get/1 internally)
      telegram_entry = ChannelRegistry.get("telegram")
      discord_entry = ChannelRegistry.get("discord")

      assert telegram_entry.module == ClawdEx.Channels.Telegram
      assert discord_entry.module == ClawdEx.Channels.Discord
    end
  end
end
