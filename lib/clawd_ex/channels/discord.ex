defmodule ClawdEx.Channels.Discord do
  @moduledoc """
  Discord 渠道实现

  使用 Nostrum 库连接 Discord Gateway 和 REST API。

  ## 配置

      config :nostrum,
        token: "YOUR_BOT_TOKEN",
        gateway_intents: [:guilds, :guild_messages, :message_content, :direct_messages]

      config :clawd_ex,
        discord_enabled: true

  ## 功能
  - 连接 Discord Gateway (WebSocket)
  - 接收消息事件
  - 发送消息/回复
  - 处理 slash commands (可选)
  """
  @behaviour ClawdEx.Channels.Channel

  use Nostrum.Consumer
  require Logger

  alias ClawdEx.Sessions.{SessionManager, SessionWorker}
  alias Nostrum.Api.Message, as: DiscordMessage
  alias Nostrum.Struct.Message

  # ============================================================================
  # Channel Behaviour Implementation
  # ============================================================================

  @impl ClawdEx.Channels.Channel
  def name, do: "discord"

  @impl ClawdEx.Channels.Channel
  def ready? do
    # 检查 Nostrum 是否已连接
    case Process.whereis(Nostrum.Shard.Supervisor) do
      nil -> false
      _pid -> true
    end
  end

  @impl ClawdEx.Channels.Channel
  def send_message(channel_id, content, opts \\ []) do
    channel_id = ensure_integer(channel_id)

    message_opts =
      %{content: content}
      |> maybe_add_reply(opts)
      |> maybe_add_buttons(opts)

    case DiscordMessage.create(channel_id, message_opts) do
      {:ok, message} ->
        {:ok, format_message(message)}

      {:error, reason} ->
        Logger.error("Discord send failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl ClawdEx.Channels.Channel
  def handle_message(message) do
    channel_id = message.channel_id
    session_key = "discord:#{channel_id}"

    # 启动或获取会话
    {:ok, _pid} =
      SessionManager.start_session(
        session_key: session_key,
        agent_id: nil,
        channel: "discord"
      )

    # 发送消息到会话
    case SessionWorker.send_message(session_key, message.content) do
      {:ok, response} ->
        send_message(channel_id, response.content, reply_to: message.id)
        :ok

      {:error, reason} ->
        Logger.error("Session error: #{inspect(reason)}")
        send_message(channel_id, "抱歉，处理消息时出错了。")
        {:error, reason}
    end
  end

  # ============================================================================
  # Nostrum Consumer Callbacks
  # ============================================================================

  @doc """
  启动 Discord consumer
  """
  def start_link do
    if enabled?() do
      Nostrum.Consumer.start_link(__MODULE__)
    else
      :ignore
    end
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, opts},
      type: :worker,
      restart: :permanent,
      shutdown: 5000
    }
  end

  @impl Nostrum.Consumer
  def handle_event({:READY, ready_data, _ws_state}) do
    Logger.info("Discord bot connected as #{ready_data.user.username}##{ready_data.user.discriminator}")
    :ok
  end

  @impl Nostrum.Consumer
  def handle_event({:MESSAGE_CREATE, %Message{} = msg, _ws_state}) do
    # 忽略来自机器人自己的消息
    unless msg.author.bot do
      process_message(msg)
    end

    :ok
  end

  @impl Nostrum.Consumer
  def handle_event({:INTERACTION_CREATE, interaction, _ws_state}) do
    # 处理 slash commands
    handle_interaction(interaction)
    :ok
  end

  # 忽略其他事件
  @impl Nostrum.Consumer
  def handle_event(_event), do: :ok

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp enabled? do
    Application.get_env(:clawd_ex, :discord_enabled, false) &&
      Application.get_env(:nostrum, :token) != nil
  end

  defp process_message(%Message{} = msg) do
    # 只处理包含内容的消息
    if msg.content && String.trim(msg.content) != "" do
      formatted = format_message(msg)
      Task.start(fn -> handle_message(formatted) end)
    end
  end

  defp handle_interaction(interaction) do
    # 处理 slash commands
    case interaction.data.name do
      "ping" ->
        respond_to_interaction(interaction, "Pong! 🏓")

      "chat" ->
        # 获取用户输入
        content = get_interaction_option(interaction, "message")
        if content do
          # 创建临时会话处理消息
          channel_id = interaction.channel_id
          session_key = "discord:#{channel_id}"

          {:ok, _pid} =
            SessionManager.start_session(
              session_key: session_key,
              agent_id: nil,
              channel: "discord"
            )

          case SessionWorker.send_message(session_key, content) do
            {:ok, response} ->
              respond_to_interaction(interaction, response.content)

            {:error, _reason} ->
              respond_to_interaction(interaction, "抱歉，处理消息时出错了。")
          end
        else
          respond_to_interaction(interaction, "请提供消息内容。")
        end

      _ ->
        respond_to_interaction(interaction, "未知命令")
    end
  end

  defp respond_to_interaction(interaction, content) do
    response = %{
      type: 4,  # CHANNEL_MESSAGE_WITH_SOURCE
      data: %{content: content}
    }

    Nostrum.Api.Interaction.create_response(interaction, response)
  end

  defp get_interaction_option(interaction, name) do
    case interaction.data.options do
      nil ->
        nil

      options ->
        Enum.find_value(options, fn opt ->
          if opt.name == name, do: opt.value
        end)
    end
  end

  defp format_message(%Message{} = msg) do
    %{
      id: to_string(msg.id),
      content: msg.content || "",
      author_id: to_string(msg.author.id),
      author_name: msg.author.username,
      channel_id: to_string(msg.channel_id),
      timestamp: msg.timestamp,
      metadata: %{
        guild_id: msg.guild_id && to_string(msg.guild_id),
        discriminator: msg.author.discriminator,
        bot: msg.author.bot || false,
        attachments: Enum.map(msg.attachments || [], &format_attachment/1),
        mentions: Enum.map(msg.mentions || [], &to_string(&1.id))
      }
    }
  end

  defp format_message(msg) when is_map(msg) do
    # 从 API 响应格式化
    %{
      id: to_string(msg.id),
      content: msg.content || "",
      author_id: to_string(msg.author.id),
      author_name: msg.author.username,
      channel_id: to_string(msg.channel_id),
      timestamp: msg.timestamp,
      metadata: %{}
    }
  end

  defp format_attachment(attachment) do
    %{
      id: to_string(attachment.id),
      filename: attachment.filename,
      url: attachment.url,
      size: attachment.size,
      content_type: attachment.content_type
    }
  end

  defp maybe_add_reply(opts_map, opts) do
    case Keyword.get(opts, :reply_to) do
      nil ->
        opts_map

      reply_id ->
        Map.put(opts_map, :message_reference, %{message_id: ensure_integer(reply_id)})
    end
  end

  defp maybe_add_buttons(opts_map, opts) do
    case Keyword.get(opts, :buttons) do
      nil ->
        opts_map

      [] ->
        opts_map

      buttons ->
        # 转换为 Discord components 格式
        components = Enum.map(buttons, fn row ->
          %{
            type: 1,  # ACTION_ROW
            components: Enum.map(row, fn button ->
              %{
                type: 2,  # BUTTON
                style: Map.get(button, :style, 1),  # PRIMARY
                label: Map.get(button, :label, "Button"),
                custom_id: Map.get(button, :callback_data, "button")
              }
            end)
          }
        end)

        Map.put(opts_map, :components, components)
    end
  end

  defp ensure_integer(value) when is_integer(value), do: value
  defp ensure_integer(value) when is_binary(value), do: String.to_integer(value)
end
