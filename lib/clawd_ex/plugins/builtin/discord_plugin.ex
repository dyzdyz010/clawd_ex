defmodule ClawdEx.Plugins.Builtin.DiscordPlugin do
  @moduledoc """
  Built-in plugin that registers the Discord channel with the Channel Registry.

  The Discord supervisor is started independently in application.ex;
  this plugin simply exposes the channel metadata so the Plugin Manager
  can register it via the standard plugin channel-registration path.
  """

  @behaviour ClawdEx.Plugins.Plugin

  @impl true
  def id, do: "discord"

  @impl true
  def name, do: "Discord"

  @impl true
  def version, do: "1.0.0"

  @impl true
  def description, do: "Built-in Discord channel"

  @impl true
  def plugin_type, do: :beam

  @impl true
  def capabilities, do: [:channels]

  @impl true
  def channels do
    [%{id: "discord", label: "Discord", module: ClawdEx.Channels.Discord, source: :builtin}]
  end

  @impl true
  def init(_config), do: {:ok, %{}}
end
