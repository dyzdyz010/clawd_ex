defmodule ClawdEx.Channels.Telegram do
  @moduledoc """
  Telegram 渠道实现
  使用 Telegex 库与 Telegram Bot API 交互
  """
  @behaviour ClawdEx.Channels.Channel

  use GenServer
  require Logger

  alias ClawdEx.Sessions.{SessionManager, SessionWorker}

  defstruct [:bot_info, :offset, :running]

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

  @impl ClawdEx.Channels.Channel
  def send_message(chat_id, content, opts \\ []) do
    reply_to = Keyword.get(opts, :reply_to)

    optional = if reply_to do
      [reply_parameters: %{message_id: String.to_integer(reply_to)}]
    else
      []
    end

    case Telegex.send_message(chat_id, content, [parse_mode: "Markdown"] ++ optional) do
      {:ok, message} ->
        {:ok, format_message(message)}

      {:error, reason} ->
        Logger.error("Telegram send failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl ClawdEx.Channels.Channel
  def handle_message(message) do
    chat_id = message.channel_id
    session_key = "telegram:#{chat_id}"

    # 启动或获取会话
    {:ok, _pid} = SessionManager.start_session(session_key,
      agent_id: nil,  # 使用默认 agent
      channel: "telegram"
    )

    # 发送消息到会话
    case SessionWorker.send_message(session_key, message.content) do
      {:ok, response} ->
        send_message(chat_id, response.content, reply_to: message.id)
        :ok

      {:error, reason} ->
        Logger.error("Session error: #{inspect(reason)}")
        send_message(chat_id, "抱歉，处理消息时出错了。")
        {:error, reason}
    end
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    # 检查是否配置了 token
    if get_token() do
      case Telegex.get_me() do
        {:ok, bot_info} ->
          Logger.info("Telegram bot started: @#{bot_info.username}")
          # 启动轮询
          send(self(), :poll)
          {:ok, %__MODULE__{bot_info: bot_info, offset: 0, running: true}}

        {:error, reason} ->
          Logger.error("Failed to get bot info: #{inspect(reason)}")
          {:stop, reason}
      end
    else
      Logger.warning("Telegram bot token not configured")
      {:ok, %__MODULE__{running: false}}
    end
  end

  @impl true
  def handle_call(:ready?, _from, state) do
    {:reply, state.running && state.bot_info != nil, state}
  end

  @impl true
  def handle_info(:poll, %{running: false} = state) do
    {:noreply, state}
  end

  def handle_info(:poll, state) do
    optional = [
      offset: state.offset,
      timeout: 30,
      allowed_updates: ["message"]
    ]

    new_offset =
      case Telegex.get_updates(optional) do
        {:ok, []} ->
          state.offset

        {:ok, updates} ->
          # 处理更新
          Enum.each(updates, &process_update/1)
          # 返回最新 offset
          updates
          |> List.last()
          |> Map.get(:update_id)
          |> Kernel.+(1)

        {:error, reason} ->
          Logger.error("Telegram poll error: #{inspect(reason)}")
          state.offset
      end

    # 继续轮询
    Process.send_after(self(), :poll, 100)
    {:noreply, %{state | offset: new_offset}}
  end

  # Private Functions

  defp process_update(%{message: message}) when not is_nil(message) do
    # 忽略非文本消息
    if message.text do
      formatted = format_message(message)

      # 异步处理消息
      Task.start(fn ->
        handle_message(formatted)
      end)
    end
  end

  defp process_update(_update), do: :ok

  defp format_message(message) do
    %{
      id: to_string(message.message_id),
      content: message.text || "",
      author_id: to_string(message.from.id),
      author_name: message.from.first_name,
      channel_id: to_string(message.chat.id),
      timestamp: DateTime.from_unix!(message.date),
      metadata: %{
        chat_type: message.chat.type,
        username: message.from.username
      }
    }
  end

  defp get_token do
    Application.get_env(:clawd_ex, :telegram_bot_token) ||
      System.get_env("TELEGRAM_BOT_TOKEN")
  end
end
