defmodule ClawdEx.Channels.DiscordSupervisor do
  @moduledoc """
  Discord channel 的 Supervisor

  负责启动和监督 Discord 相关进程：
  - Nostrum application (Discord Gateway)
  - Discord Consumer (事件处理)
  """

  use Supervisor
  require Logger

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    if enabled?() do
      Logger.info("Starting Discord channel supervisor...")

      children = [
        # Nostrum Application 会自动启动 Gateway 连接
        # Discord Consumer 处理事件
        {ClawdEx.Channels.Discord, []}
      ]

      Supervisor.init(children, strategy: :one_for_one)
    else
      Logger.info("Discord channel disabled, skipping...")
      :ignore
    end
  end

  defp enabled? do
    Application.get_env(:clawd_ex, :discord_enabled, false) &&
      Application.get_env(:nostrum, :token) != nil
  end

  @doc """
  检查 Discord 是否已启动并连接
  """
  def ready? do
    case Process.whereis(__MODULE__) do
      nil -> false
      _pid -> ClawdEx.Channels.Discord.ready?()
    end
  end

  @doc """
  注册 slash commands 到 Discord

  可以在应用启动后调用，或者在运行时动态注册。

  ## 示例

      ClawdEx.Channels.DiscordSupervisor.register_commands()
  """
  def register_commands do
    if ready?() do
      commands = [
        %{
          name: "ping",
          description: "检查机器人是否在线"
        },
        %{
          name: "chat",
          description: "与 AI 聊天",
          options: [
            %{
              type: 3,  # STRING
              name: "message",
              description: "你想说什么？",
              required: true
            }
          ]
        }
      ]

      # 获取当前应用 ID
      case Nostrum.Api.Self.get() do
        {:ok, user} ->
          # 注册全局命令
          case Nostrum.Api.ApplicationCommand.bulk_overwrite_global_commands(user.id, commands) do
            {:ok, _} ->
              Logger.info("Successfully registered #{length(commands)} slash commands")
              :ok

            {:error, reason} ->
              Logger.error("Failed to register slash commands: #{inspect(reason)}")
              {:error, reason}
          end

        {:error, reason} ->
          Logger.error("Failed to get bot user: #{inspect(reason)}")
          {:error, reason}
      end
    else
      {:error, :not_ready}
    end
  end
end
