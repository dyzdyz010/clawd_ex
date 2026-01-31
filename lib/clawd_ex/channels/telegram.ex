defmodule ClawdEx.Channels.Telegram do
  @moduledoc """
  Telegram 渠道实现 (简化版)

  TODO: 使用 Telegex 或直接实现 Bot API
  """
  @behaviour ClawdEx.Channels.Channel

  use GenServer
  require Logger

  alias ClawdEx.Sessions.{SessionManager, SessionWorker}

  defstruct [:bot_token, :bot_info, :offset, :running]

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
    token = get_token()

    if is_nil(token) do
      {:error, :missing_bot_token}
    else
      body = %{
        chat_id: chat_id,
        text: content,
        parse_mode: "Markdown"
      }

      body =
        case Keyword.get(opts, :reply_to) do
          nil -> body
          reply_id -> Map.put(body, :reply_parameters, %{message_id: reply_id})
        end

      url = "https://api.telegram.org/bot#{token}/sendMessage"

      case Req.post(url, json: body) do
        {:ok, %{status: 200, body: %{"ok" => true, "result" => message}}} ->
          {:ok, format_message(message)}

        {:ok, %{status: _status, body: body}} ->
          Logger.error("Telegram send failed: #{inspect(body)}")
          {:error, body}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @impl ClawdEx.Channels.Channel
  def handle_message(message) do
    chat_id = message.channel_id
    session_key = "telegram:#{chat_id}"

    # 启动或获取会话
    {:ok, _pid} =
      SessionManager.start_session(
        session_key: session_key,
        agent_id: nil,
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
    token = get_token()

    if token do
      case get_me(token) do
        {:ok, bot_info} ->
          Logger.info("Telegram bot started: @#{bot_info["username"]}")
          send(self(), :poll)
          {:ok, %__MODULE__{bot_token: token, bot_info: bot_info, offset: 0, running: true}}

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
    new_offset = poll_updates(state)
    Process.send_after(self(), :poll, 100)
    {:noreply, %{state | offset: new_offset}}
  end

  # Private Functions

  defp get_me(token) do
    url = "https://api.telegram.org/bot#{token}/getMe"

    case Req.get(url) do
      {:ok, %{status: 200, body: %{"ok" => true, "result" => result}}} ->
        {:ok, result}

      {:ok, %{body: body}} ->
        {:error, body}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp poll_updates(state) do
    url = "https://api.telegram.org/bot#{state.bot_token}/getUpdates"
    params = [offset: state.offset, timeout: 30, allowed_updates: ["message"]]

    case Req.get(url, params: params) do
      {:ok, %{status: 200, body: %{"ok" => true, "result" => []}}} ->
        state.offset

      {:ok, %{status: 200, body: %{"ok" => true, "result" => updates}}} ->
        Enum.each(updates, &process_update/1)

        updates
        |> List.last()
        |> Map.get("update_id")
        |> Kernel.+(1)

      {:ok, %{body: body}} ->
        Logger.error("Telegram poll error: #{inspect(body)}")
        state.offset

      {:error, reason} ->
        Logger.error("Telegram poll error: #{inspect(reason)}")
        state.offset
    end
  end

  defp process_update(%{"message" => message}) when is_map(message) do
    if message["text"] do
      formatted = format_message(message)
      Task.start(fn -> handle_message(formatted) end)
    end
  end

  defp process_update(_), do: :ok

  defp format_message(message) do
    %{
      id: to_string(message["message_id"]),
      content: message["text"] || "",
      author_id: to_string(message["from"]["id"]),
      author_name: message["from"]["first_name"],
      channel_id: to_string(message["chat"]["id"]),
      timestamp: DateTime.from_unix!(message["date"]),
      metadata: %{
        chat_type: message["chat"]["type"],
        username: message["from"]["username"]
      }
    }
  end

  defp get_token do
    Application.get_env(:clawd_ex, :telegram_bot_token) ||
      System.get_env("TELEGRAM_BOT_TOKEN")
  end
end
