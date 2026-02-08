defmodule ClawdEx.Channels.ChannelDispatcher do
  @moduledoc """
  渠道消息分发器 - 统一处理不同渠道的消息发送

  监听 Agent Loop 的事件，将消息段（segment）发送到对应渠道。

  Events:
  - {:agent_segment, session_id, content, opts} - 完整的消息段，需要发送
  - {:agent_done, session_id, content} - 最终消息

  这样不同渠道可以有统一的行为：
  - 网页版：实时流式显示
  - Telegram/Discord：分段发送完整消息
  """

  use GenServer
  require Logger

  alias ClawdEx.Channels.{Telegram, Discord}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  注册一个会话到渠道
  """
  def register_session(session_key, channel, channel_id, opts \\ []) do
    GenServer.cast(__MODULE__, {:register, session_key, channel, channel_id, opts})
  end

  @doc """
  注销会话
  """
  def unregister_session(session_key) do
    GenServer.cast(__MODULE__, {:unregister, session_key})
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    # session_key -> %{channel: "telegram", channel_id: "123", reply_to: nil}
    {:ok, %{sessions: %{}}}
  end

  @impl true
  def handle_cast({:register, session_key, channel, channel_id, opts}, state) do
    session_info = %{
      channel: channel,
      channel_id: channel_id,
      reply_to: Keyword.get(opts, :reply_to),
      last_message_id: nil
    }

    # 订阅 agent 事件
    if session_id = get_session_id(session_key) do
      Phoenix.PubSub.subscribe(ClawdEx.PubSub, "agent:#{session_id}")
    end

    {:noreply, put_in(state, [:sessions, session_key], session_info)}
  end

  @impl true
  def handle_cast({:unregister, session_key}, state) do
    {:noreply, update_in(state, [:sessions], &Map.delete(&1, session_key))}
  end

  # 处理消息段 - 当 AI 输出完整文本段落时
  @impl true
  def handle_info({:agent_segment, run_id, content, opts}, state) do
    session_key = opts[:session_key]

    case get_in(state, [:sessions, session_key]) do
      nil ->
        {:noreply, state}

      session_info ->
        # 发送消息段到渠道
        if content && content != "" do
          send_to_channel(session_info, content)
        end

        {:noreply, state}
    end
  end

  # 忽略其他 agent 事件
  @impl true
  def handle_info({:agent_chunk, _run_id, _chunk}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:agent_status, _run_id, _status, _details}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Private

  defp send_to_channel(%{channel: "telegram", channel_id: channel_id, reply_to: reply_to}, content) do
    opts = if reply_to, do: [reply_to: reply_to], else: []
    Telegram.send_message(channel_id, content, opts)
  end

  defp send_to_channel(%{channel: "discord", channel_id: channel_id}, content) do
    Discord.send_message(channel_id, content)
  end

  defp send_to_channel(_session_info, _content) do
    :ok
  end

  defp get_session_id(session_key) do
    case ClawdEx.Repo.get_by(ClawdEx.Sessions.Session, session_key: session_key) do
      nil -> nil
      session -> session.id
    end
  end
end
