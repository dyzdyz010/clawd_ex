defmodule ClawdEx.Tools.Message do
  @moduledoc """
  多渠道消息工具

  通过统一接口发送消息到不同渠道 (Telegram/Discord)。
  支持发送文本、媒体、添加反应和删除消息。
  """
  @behaviour ClawdEx.Tools.Tool

  require Logger

  alias ClawdEx.Channels.Telegram, as: TelegramChannel
  alias ClawdEx.Channels.Discord

  @impl true
  def name, do: "message"

  @impl true
  def description do
    """
    Send, delete, and manage messages via channel adapters.

    Supports multiple channels:
    - telegram: Send messages to Telegram chats
    - discord: Send messages to Discord channels

    Actions:
    - send: Send a text message (with optional media)
    - react: Add an emoji reaction to a message
    - delete: Delete a message
    """
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        action: %{
          type: "string",
          enum: ["send", "react", "delete"],
          description: "The action to perform"
        },
        channel: %{
          type: "string",
          enum: ["telegram", "discord"],
          description: "The channel to use (telegram or discord)"
        },
        target: %{
          type: "string",
          description: "Target channel/chat ID to send the message to"
        },
        message: %{
          type: "string",
          description: "The message content to send (for 'send' action)"
        },
        messageId: %{
          type: "string",
          description: "Message ID (for 'react' and 'delete' actions)"
        },
        emoji: %{
          type: "string",
          description: "Emoji to react with (for 'react' action)"
        },
        replyTo: %{
          type: "string",
          description: "Message ID to reply to (for 'send' action)"
        },
        media: %{
          type: "string",
          description: "Media URL or file path (for 'send' action)"
        },
        caption: %{
          type: "string",
          description: "Caption for media (for 'send' action with media)"
        }
      },
      required: ["action", "channel", "target"]
    }
  end

  @impl true
  def execute(params, context) do
    action = get_param(params, :action)
    channel = get_param(params, :channel)
    target = get_param(params, :target)

    cond do
      is_nil(action) or action == "" ->
        {:error, "action is required"}

      is_nil(channel) or channel == "" ->
        {:error, "channel is required"}

      is_nil(target) or target == "" ->
        {:error, "target is required"}

      action not in ["send", "react", "delete"] ->
        {:error, "Invalid action: #{action}. Must be one of: send, react, delete"}

      channel not in ["telegram", "discord"] ->
        {:error, "Invalid channel: #{channel}. Must be one of: telegram, discord"}

      true ->
        execute_action(action, channel, target, params, context)
    end
  end

  # ============================================================================
  # Action Handlers
  # ============================================================================

  defp execute_action("send", channel, target, params, _context) do
    message = get_param(params, :message)
    media = get_param(params, :media)
    reply_to = get_param(params, :replyTo)
    caption = get_param(params, :caption)

    cond do
      is_nil(message) and is_nil(media) ->
        {:error, "Either 'message' or 'media' is required for send action"}

      not is_nil(media) ->
        send_media(channel, target, media, caption || message, reply_to: reply_to)

      true ->
        send_text(channel, target, message, reply_to: reply_to)
    end
  end

  defp execute_action("react", channel, target, params, _context) do
    message_id = get_param(params, :messageId)
    emoji = get_param(params, :emoji)

    cond do
      is_nil(message_id) or message_id == "" ->
        {:error, "messageId is required for react action"}

      is_nil(emoji) or emoji == "" ->
        {:error, "emoji is required for react action"}

      true ->
        add_reaction(channel, target, message_id, emoji)
    end
  end

  defp execute_action("delete", channel, target, params, _context) do
    message_id = get_param(params, :messageId)

    if is_nil(message_id) or message_id == "" do
      {:error, "messageId is required for delete action"}
    else
      delete_message(channel, target, message_id)
    end
  end

  # ============================================================================
  # Channel Routing - Send Text
  # ============================================================================

  defp send_text("telegram", target, message, opts) do
    case check_channel_ready?(TelegramChannel) do
      :ok ->
        case TelegramChannel.send_message(target, message, opts) do
          {:ok, result} ->
            {:ok, format_send_result("telegram", result)}

          {:error, reason} ->
            {:error, "Telegram send failed: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp send_text("discord", target, message, opts) do
    case check_channel_ready?(Discord) do
      :ok ->
        case Discord.send_message(target, message, opts) do
          {:ok, result} ->
            {:ok, format_send_result("discord", result)}

          {:error, reason} ->
            {:error, "Discord send failed: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ============================================================================
  # Channel Routing - Send Media
  # ============================================================================

  defp send_media("telegram", target, media_url, caption, opts) do
    case check_channel_ready?(TelegramChannel) do
      :ok ->
        send_telegram_media(target, media_url, caption, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp send_media("discord", target, media_url, caption, opts) do
    case check_channel_ready?(Discord) do
      :ok ->
        # Discord: 发送带媒体 URL 的消息
        content =
          if caption && String.trim(caption) != "" do
            "#{caption}\n#{media_url}"
          else
            media_url
          end

        case Discord.send_message(target, content, opts) do
          {:ok, result} ->
            {:ok, format_send_result("discord", result)}

          {:error, reason} ->
            {:error, "Discord media send failed: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp send_telegram_media(chat_id, media_url, caption, opts) do
    token = TelegramChannel.get_token()

    if is_nil(token) do
      {:error, "Telegram bot not configured"}
    else
      do_send_telegram_media(token, chat_id, media_url, caption, opts)
    end
  end

  defp do_send_telegram_media(token, chat_id, media_url, caption, opts) do
    chat_id = ensure_integer(chat_id)
    reply_to = Keyword.get(opts, :reply_to)

    # 根据 URL 后缀判断媒体类型
    media_type = detect_media_type(media_url)

    # 确定 API 方法
    method =
      case media_type do
        :photo -> "sendPhoto"
        :video -> "sendVideo"
        :audio -> "sendAudio"
        :document -> "sendDocument"
        :animation -> "sendAnimation"
      end

    # 确定媒体参数名
    media_param =
      case media_type do
        :photo -> :photo
        :video -> :video
        :audio -> :audio
        :document -> :document
        :animation -> :animation
      end

    params =
      [{:chat_id, chat_id}, {media_param, media_url}]
      |> maybe_add_caption(caption)
      |> maybe_add_reply_params(reply_to)

    case Telegram.Api.request(token, method, params) do
      {:ok, message} ->
        {:ok,
         %{
           channel: "telegram",
           messageId: to_string(message["message_id"]),
           chatId: to_string(message["chat"]["id"]),
           mediaType: media_type
         }}

      {:error, %{"description" => description}} ->
        {:error, "Telegram media send failed: #{description}"}

      {:error, reason} ->
        {:error, "Telegram media send failed: #{inspect(reason)}"}
    end
  end

  # ============================================================================
  # Channel Routing - React
  # ============================================================================

  defp add_reaction("telegram", chat_id, message_id, emoji) do
    token = TelegramChannel.get_token()

    if is_nil(token) do
      {:error, "Telegram bot not configured"}
    else
      do_add_telegram_reaction(token, chat_id, message_id, emoji)
    end
  end

  defp add_reaction("discord", channel_id, message_id, emoji) do
    channel_id = ensure_integer(channel_id)
    message_id = ensure_integer(message_id)

    case Nostrum.Api.Message.react(channel_id, message_id, emoji) do
      {:ok} ->
        {:ok,
         %{
           channel: "discord",
           action: "react",
           channelId: to_string(channel_id),
           messageId: to_string(message_id),
           emoji: emoji
         }}

      {:error, reason} ->
        {:error, "Discord react failed: #{inspect(reason)}"}
    end
  end

  defp do_add_telegram_reaction(token, chat_id, message_id, emoji) do
    chat_id = ensure_integer(chat_id)
    message_id = ensure_integer(message_id)

    # Telegram 使用 setMessageReaction API
    reaction = [%{type: "emoji", emoji: emoji}]

    params = [
      chat_id: chat_id,
      message_id: message_id,
      reaction: {:json, reaction}
    ]

    case Telegram.Api.request(token, "setMessageReaction", params) do
      {:ok, _} ->
        {:ok,
         %{
           channel: "telegram",
           action: "react",
           chatId: to_string(chat_id),
           messageId: to_string(message_id),
           emoji: emoji
         }}

      {:error, %{"description" => description}} ->
        {:error, "Telegram react failed: #{description}"}

      {:error, reason} ->
        {:error, "Telegram react failed: #{inspect(reason)}"}
    end
  end

  # ============================================================================
  # Channel Routing - Delete
  # ============================================================================

  defp delete_message("telegram", chat_id, message_id) do
    token = TelegramChannel.get_token()

    if is_nil(token) do
      {:error, "Telegram bot not configured"}
    else
      do_delete_telegram_message(token, chat_id, message_id)
    end
  end

  defp delete_message("discord", channel_id, message_id) do
    channel_id = ensure_integer(channel_id)
    message_id = ensure_integer(message_id)

    case Nostrum.Api.Message.delete(channel_id, message_id) do
      {:ok} ->
        {:ok,
         %{
           channel: "discord",
           action: "delete",
           channelId: to_string(channel_id),
           messageId: to_string(message_id),
           deleted: true
         }}

      {:error, reason} ->
        {:error, "Discord delete failed: #{inspect(reason)}"}
    end
  end

  defp do_delete_telegram_message(token, chat_id, message_id) do
    chat_id = ensure_integer(chat_id)
    message_id = ensure_integer(message_id)

    params = [chat_id: chat_id, message_id: message_id]

    case Telegram.Api.request(token, "deleteMessage", params) do
      {:ok, true} ->
        {:ok,
         %{
           channel: "telegram",
           action: "delete",
           chatId: to_string(chat_id),
           messageId: to_string(message_id),
           deleted: true
         }}

      {:error, %{"description" => description}} ->
        {:error, "Telegram delete failed: #{description}"}

      {:error, reason} ->
        {:error, "Telegram delete failed: #{inspect(reason)}"}
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp get_param(params, key) do
    params[to_string(key)] || params[key]
  end

  defp ensure_integer(value) when is_integer(value), do: value
  defp ensure_integer(value) when is_binary(value), do: String.to_integer(value)

  defp check_channel_ready?(module) do
    if module.ready?() do
      :ok
    else
      {:error, "Channel #{module.name()} is not ready"}
    end
  end

  defp format_send_result(channel, result) do
    %{
      channel: channel,
      action: "send",
      messageId: result[:id],
      chatId: result[:channel_id],
      content: result[:content]
    }
  end

  defp detect_media_type(url) do
    url_lower = String.downcase(url)

    cond do
      String.contains?(url_lower, [".jpg", ".jpeg", ".png", ".webp"]) -> :photo
      String.contains?(url_lower, [".mp4", ".mov", ".avi", ".mkv"]) -> :video
      String.contains?(url_lower, [".mp3", ".ogg", ".wav", ".flac", ".m4a"]) -> :audio
      String.contains?(url_lower, [".gif"]) -> :animation
      true -> :document
    end
  end

  defp maybe_add_caption(params, nil), do: params
  defp maybe_add_caption(params, ""), do: params
  defp maybe_add_caption(params, caption), do: Keyword.put(params, :caption, caption)

  defp maybe_add_reply_params(params, nil), do: params

  defp maybe_add_reply_params(params, reply_id) do
    reply_params = %{message_id: ensure_integer(reply_id)}
    Keyword.put(params, :reply_parameters, {:json, reply_params})
  end
end
