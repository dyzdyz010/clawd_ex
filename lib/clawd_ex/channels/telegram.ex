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
    GenServer.call(__MODULE__, :get_token)
  catch
    :exit, _ -> nil
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
