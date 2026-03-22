defmodule ClawdEx.Plugins.Builtin.TelegramPlugin do
  @moduledoc """
  Built-in plugin that registers the Telegram channel with the Channel Registry.

  The Telegram supervisor is started independently in application.ex;
  this plugin simply exposes the channel metadata so the Plugin Manager
  can register it via the standard plugin channel-registration path.
  """

  @behaviour ClawdEx.Plugins.Plugin

  @impl true
  def id, do: "telegram"

  @impl true
  def name, do: "Telegram"

  @impl true
  def version, do: "1.0.0"

  @impl true
  def description, do: "Built-in Telegram channel"

  @impl true
  def plugin_type, do: :beam

  @impl true
  def capabilities, do: [:channels]

  @impl true
  def channels do
    [%{id: "telegram", label: "Telegram", module: ClawdEx.Channels.Telegram, source: :builtin}]
  end

  @impl true
  def init(_config), do: {:ok, %{}}
end
