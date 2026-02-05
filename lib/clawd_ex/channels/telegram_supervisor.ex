defmodule ClawdEx.Channels.TelegramSupervisor do
  @moduledoc """
  Telegram channel 的 Supervisor

  负责启动和监督 Telegram 相关进程：
  - Telegram Bot (长轮询获取更新)
  """

  use Supervisor
  require Logger

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    if enabled?() do
      Logger.info("Starting Telegram channel supervisor...")

      children = [
        {ClawdEx.Channels.Telegram, []}
      ]

      Supervisor.init(children, strategy: :one_for_one)
    else
      Logger.info("Telegram channel disabled (no token configured), skipping...")
      :ignore
    end
  end

  defp enabled? do
    token =
      Application.get_env(:clawd_ex, :telegram_bot_token) ||
        System.get_env("TELEGRAM_BOT_TOKEN")

    token != nil && token != ""
  end

  @doc """
  检查 Telegram 是否已启动并连接
  """
  def ready? do
    case Process.whereis(__MODULE__) do
      nil -> false
      _pid -> ClawdEx.Channels.Telegram.ready?()
    end
  end
end
