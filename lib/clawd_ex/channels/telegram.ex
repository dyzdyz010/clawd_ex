defmodule ClawdEx.Channels.Telegram do
  @moduledoc """
  Telegram 渠道实现

  使用 visciang/telegram 库处理 Telegram Bot API 调用
  """
  @behaviour ClawdEx.Channels.Channel

  use GenServer
  require Logger

  alias ClawdEx.Sessions.{SessionManager, SessionWorker}

  defstruct [:token, :bot_info, :offset, :running]

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl ClawdEx.Channels.Channel
  def name, do: "telegram"

  @impl ClawdEx.Channels.Channel
  def ready? do
    GenServer.call(__MODULE__, :ready?)
  catch
    :exit, _ -> false
  end

  @doc """
  获取当前 bot token
  """
  def get_token do
    # 优先从 GenServer 获取，失败则从 Application config 获取
    case GenServer.call(__MODULE__, :get_token) do
      nil -> get_token_from_config()
      token -> token
    end
  catch
    :exit, _ -> get_token_from_config()
  end

  defp get_token_from_config do
    Application.get_env(:clawd_ex, :telegram_bot_token) ||
      System.get_env("TELEGRAM_BOT_TOKEN")
  end

  @impl ClawdEx.Channels.Channel
  def send_message(chat_id, content, opts \\ []) do
    token = get_token()

    if token do
      do_send_message(token, chat_id, content, opts)
    else
      {:error, "Telegram bot not configured"}
    end
  end

  defp do_send_message(token, chat_id, content, opts) do
    chat_id = ensure_integer(chat_id)
    reply_to = Keyword.get(opts, :reply_to)

    params =
      [chat_id: chat_id, text: content, parse_mode: "Markdown"]
      |> maybe_add_reply_params(reply_to)

    case Telegram.Api.request(token, "sendMessage", params) do
      {:ok, message} ->
        {:ok, format_message(message)}

      {:error, %{"description" => description}} ->
        Logger.error("Telegram send failed: #{description}")
        {:error, description}

      {:error, reason} ->
        Logger.error("Telegram send failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  发送图片到 Telegram
  支持文件路径或 URL
  """
  def send_photo(chat_id, photo_path, opts \\ []) do
    token = get_token()

    if token do
      do_send_photo(token, chat_id, photo_path, opts)
    else
      {:error, "Telegram bot not configured"}
    end
  end

  defp do_send_photo(token, chat_id, photo_path, opts) do
    chat_id = ensure_integer(chat_id)
    caption = Keyword.get(opts, :caption)
    reply_to = Keyword.get(opts, :reply_to)

    # 判断是文件路径还是 URL
    photo_param =
      if String.starts_with?(photo_path, "http") do
        # URL 直接发送
        photo_path
      else
        # 文件路径，使用 multipart 上传
        {:file, photo_path}
      end

    params =
      [chat_id: chat_id, photo: photo_param]
      |> maybe_add_caption(caption)
      |> maybe_add_reply_params(reply_to)

    case Telegram.Api.request(token, "sendPhoto", params) do
      {:ok, message} ->
        {:ok, format_message(message)}

      {:error, %{"description" => description}} ->
        Logger.error("Telegram send photo failed: #{description}")
        {:error, description}

      {:error, reason} ->
        Logger.error("Telegram send photo failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp maybe_add_caption(params, nil), do: params
  defp maybe_add_caption(params, caption), do: Keyword.put(params, :caption, caption)

  @doc """
  发送聊天动作（如 typing 状态）
  """
  def send_chat_action(chat_id, action \\ "typing") do
    token = get_token()

    if token do
      chat_id = ensure_integer(chat_id)
      Telegram.Api.request(token, "sendChatAction", chat_id: chat_id, action: action)
    else
      {:error, "Telegram bot not configured"}
    end
  end

  @doc """
  启动持续的 typing 指示器，返回停止函数
  Telegram typing 状态约 5 秒后过期，所以每 4 秒发送一次
  """
  def start_typing_indicator(chat_id) do
    parent = self()
    ref = make_ref()

    pid = spawn(fn ->
      typing_loop(chat_id, parent, ref)
    end)

    # 返回停止函数
    fn -> send(pid, {:stop, ref}) end
  end

  defp typing_loop(chat_id, parent, ref) do
    send_chat_action(chat_id, "typing")

    receive do
      {:stop, ^ref} -> :ok
    after
      4_000 -> typing_loop(chat_id, parent, ref)
    end
  end

  @impl ClawdEx.Channels.Channel
  def handle_message(message) do
    chat_id = message.channel_id
    session_key = "telegram:#{chat_id}"

    # 启动或获取会话
    case SessionManager.start_session(
           session_key: session_key,
           agent_id: nil,
           channel: "telegram"
         ) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} ->
        Logger.error("Failed to start session: #{inspect(reason)}")
        :error
    end

    # 启动持续的 typing 指示器
    stop_typing = start_typing_indicator(chat_id)

    # 发送消息到会话
    result = SessionWorker.send_message(session_key, message.content)

    # 停止 typing 指示器
    stop_typing.()

    case result do
      {:ok, response} when is_binary(response) ->
        Logger.info("Sending Telegram response to #{chat_id}: #{String.slice(response, 0, 50)}...")
        send_response_with_media(chat_id, response, reply_to: message.id)
        :ok

      {:error, reason} ->
        Logger.error("Session error: #{inspect(reason)}")
        send_message(chat_id, "抱歉，处理消息时出错了。")
        {:error, reason}
    end
  end

  # 解析响应并发送，支持文本和媒体混合
  defp send_response_with_media(chat_id, response, opts) do
    # 解析 MEDIA: 标记的图片路径
    # 格式: MEDIA: /path/to/image.png 或 MEDIA: https://...
    media_regex = ~r/MEDIA:\s*(\S+\.(?:png|jpg|jpeg|gif|webp))/i

    case Regex.scan(media_regex, response) do
      [] ->
        # 没有媒体，直接发送文本
        case send_message(chat_id, response, opts) do
          {:ok, _} -> Logger.info("Telegram message sent successfully")
          {:error, err} -> Logger.error("Telegram send failed: #{inspect(err)}")
        end

      media_matches ->
        # 有媒体文件，分别处理
        # 先发送去除 MEDIA 标记的文本（如果有的话）
        text_content = Regex.replace(media_regex, response, "") |> String.trim()

        if text_content != "" do
          case send_message(chat_id, text_content, opts) do
            {:ok, _} -> Logger.info("Telegram text message sent")
            {:error, err} -> Logger.error("Telegram text send failed: #{inspect(err)}")
          end
        end

        # 发送所有媒体文件
        Enum.each(media_matches, fn [_full_match, path] ->
          Logger.info("Sending media: #{path}")
          case send_photo(chat_id, path, opts) do
            {:ok, _} -> Logger.info("Telegram photo sent successfully: #{path}")
            {:error, err} -> Logger.error("Telegram photo send failed: #{inspect(err)}")
          end
        end)
    end
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    case configure_token() do
      {:ok, token} ->
        case Telegram.Api.request(token, "getMe") do
          {:ok, bot_info} ->
            Logger.info("Telegram bot started: @#{bot_info["username"]}")
            send(self(), :poll)
            {:ok, %__MODULE__{token: token, bot_info: bot_info, offset: 0, running: true}}

          {:error, reason} ->
            Logger.error("Failed to get bot info: #{inspect(reason)}")
            {:stop, reason}
        end

      :no_token ->
        Logger.warning("Telegram bot token not configured")
        {:ok, %__MODULE__{running: false}}
    end
  end

  @impl true
  def handle_call(:ready?, _from, state) do
    {:reply, state.running && state.bot_info != nil, state}
  end

  def handle_call(:get_token, _from, state) do
    {:reply, state.token, state}
  end

  @impl true
  def handle_info(:poll, %{running: false} = state) do
    {:noreply, state}
  end

  def handle_info(:poll, state) do
    new_offset = poll_updates(state)
    Process.send_after(self(), :poll, 100)
    {:noreply, %{state | offset: new_offset}}
  end

  # Private Functions

  defp configure_token do
    token =
      Application.get_env(:clawd_ex, :telegram_bot_token) ||
        System.get_env("TELEGRAM_BOT_TOKEN")

    if token do
      {:ok, token}
    else
      :no_token
    end
  end

  defp poll_updates(state) do
    params = [offset: state.offset, timeout: 30, allowed_updates: ["message"]]

    case Telegram.Api.request(state.token, "getUpdates", params) do
      {:ok, []} ->
        state.offset

      {:ok, updates} ->
        Enum.each(updates, &process_update/1)

        updates
        |> List.last()
        |> Map.get("update_id")
        |> Kernel.+(1)

      {:error, reason} ->
        Logger.error("Telegram poll error: #{inspect(reason)}")
        state.offset
    end
  end

  defp process_update(%{"message" => message}) when not is_nil(message) do
    if message["text"] do
      formatted = format_message(message)
      Task.start(fn -> handle_message(formatted) end)
    end
  end

  defp process_update(_), do: :ok

  defp format_message(message) do
    from = message["from"] || %{}
    chat = message["chat"] || %{}

    %{
      id: to_string(message["message_id"]),
      content: message["text"] || "",
      author_id: to_string(from["id"]),
      author_name: from["first_name"] || "",
      channel_id: to_string(chat["id"]),
      timestamp: DateTime.from_unix!(message["date"] || 0),
      metadata: %{
        chat_type: chat["type"],
        username: from["username"]
      }
    }
  end

  defp ensure_integer(value) when is_integer(value), do: value
  defp ensure_integer(value) when is_binary(value), do: String.to_integer(value)

  defp maybe_add_reply_params(params, nil), do: params

  defp maybe_add_reply_params(params, reply_id) do
    reply_params = %{message_id: ensure_integer(reply_id)}
    Keyword.put(params, :reply_parameters, {:json, reply_params})
  end
end
