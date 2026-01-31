defmodule ClawdEx.Streaming.BlockStreamer do
  @moduledoc """
  Block Streamer - 流式响应块发送器

  管理流式响应的块发送，支持：
  - 实时块发送到 Phoenix Channel
  - Human-like pacing（人性化延迟）
  - 合并（coalescing）小块
  - 断点偏好配置

  ## 配置示例

      config :clawd_ex, :block_streaming,
        enabled: true,
        break: :text_end,  # :text_end | :message_end
        chunk: [
          min_chars: 200,
          max_chars: 800,
          break_preference: :paragraph
        ],
        coalesce: [
          min_chars: 100,
          max_chars: 1500,
          idle_ms: 500
        ],
        human_delay: [
          mode: :natural,  # :off | :natural | :custom
          min_ms: 800,
          max_ms: 2500
        ]

  """

  use GenServer

  alias ClawdEx.Streaming.BlockChunker

  require Logger

  defstruct [
    :session_id,
    :run_id,
    :chunker,
    :config,
    :coalesce_buffer,
    :idle_timer,
    :blocks_sent,
    :started_at
  ]

  @type config :: %{
          enabled: boolean(),
          break: :text_end | :message_end,
          chunk: keyword(),
          coalesce: keyword() | nil,
          human_delay: keyword()
        }

  @default_config %{
    enabled: false,
    break: :message_end,
    chunk: [min_chars: 200, max_chars: 800, break_preference: :paragraph],
    coalesce: nil,
    human_delay: [mode: :off]
  }

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  启动 Block Streamer
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  推送文本到 streamer
  """
  @spec push(pid(), String.t()) :: :ok
  def push(pid, text) do
    GenServer.cast(pid, {:push, text})
  end

  @doc """
  文本块结束（AI 输出一个 text block 完成）
  """
  @spec text_end(pid()) :: :ok
  def text_end(pid) do
    GenServer.cast(pid, :text_end)
  end

  @doc """
  消息结束（AI 响应完全结束）
  """
  @spec message_end(pid()) :: {[String.t()], non_neg_integer()}
  def message_end(pid) do
    GenServer.call(pid, :message_end)
  end

  @doc """
  获取当前状态
  """
  @spec get_state(pid()) :: map()
  def get_state(pid) do
    GenServer.call(pid, :get_state)
  end

  @doc """
  停止 streamer
  """
  def stop(pid) do
    GenServer.stop(pid, :normal)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    run_id = Keyword.fetch!(opts, :run_id)
    config = Keyword.get(opts, :config, %{})

    # 合并配置
    merged_config = Map.merge(@default_config, config)

    # 创建分块器
    chunk_opts = merged_config.chunk
    chunker = BlockChunker.new(chunk_opts)

    state = %__MODULE__{
      session_id: session_id,
      run_id: run_id,
      chunker: chunker,
      config: merged_config,
      coalesce_buffer: [],
      idle_timer: nil,
      blocks_sent: 0,
      started_at: DateTime.utc_now()
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:push, text}, state) do
    if state.config.enabled do
      {chunks, new_chunker} = BlockChunker.push(state.chunker, text)

      new_state = %{state | chunker: new_chunker}

      # 根据 break 设置决定是否立即发送
      new_state =
        case state.config.break do
          :text_end ->
            # text_end 模式下，块准备好就可以发送（但等待 text_end 事件）
            maybe_coalesce(new_state, chunks)

          :message_end ->
            # message_end 模式下，只缓存，不发送
            buffer_chunks(new_state, chunks)
        end

      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast(:text_end, state) do
    if state.config.enabled && state.config.break == :text_end do
      # 刷新当前 chunker 并发送
      {chunks, new_chunker} = BlockChunker.flush(state.chunker)
      new_state = %{state | chunker: new_chunker}
      new_state = send_blocks(new_state, chunks)
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_call(:message_end, _from, state) do
    # 刷新所有内容
    {chunks, new_chunker} = BlockChunker.flush(state.chunker)

    # 合并 coalesce buffer 中的块
    all_chunks =
      (state.coalesce_buffer ++ chunks)
      |> Enum.filter(&(&1 != ""))

    new_state = %{state | chunker: new_chunker, coalesce_buffer: []}

    # 发送所有剩余块
    new_state = send_blocks(new_state, all_chunks)

    {:reply, {all_chunks, new_state.blocks_sent}, new_state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    info = %{
      session_id: state.session_id,
      run_id: state.run_id,
      blocks_sent: state.blocks_sent,
      buffer_size: String.length(BlockChunker.peek(state.chunker)),
      coalesce_buffer_count: length(state.coalesce_buffer),
      enabled: state.config.enabled
    }

    {:reply, info, state}
  end

  @impl true
  def handle_info(:coalesce_idle, state) do
    # Idle 超时，刷新 coalesce buffer
    if state.coalesce_buffer != [] do
      new_state = flush_coalesce_buffer(state)
      {:noreply, %{new_state | idle_timer: nil}}
    else
      {:noreply, %{state | idle_timer: nil}}
    end
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  # 缓存块（message_end 模式）
  defp buffer_chunks(state, chunks) do
    %{state | coalesce_buffer: state.coalesce_buffer ++ chunks}
  end

  # 合并处理（text_end 模式）
  defp maybe_coalesce(state, chunks) do
    case state.config.coalesce do
      nil ->
        # 没有 coalesce 配置，直接发送
        send_blocks(state, chunks)

      coalesce_config ->
        # 有 coalesce 配置，进入合并逻辑
        coalesce_chunks(state, chunks, coalesce_config)
    end
  end

  # 合并块
  defp coalesce_chunks(state, chunks, config) do
    min_chars = Keyword.get(config, :min_chars, 100)
    max_chars = Keyword.get(config, :max_chars, 1500)
    idle_ms = Keyword.get(config, :idle_ms, 500)

    # 取消旧的 idle timer
    if state.idle_timer, do: Process.cancel_timer(state.idle_timer)

    # 添加新块到 buffer
    new_buffer = state.coalesce_buffer ++ chunks

    # 计算合并后的大小
    combined_text = Enum.join(new_buffer, get_joiner(state.config.chunk[:break_preference]))
    combined_size = String.length(combined_text)

    cond do
      # 超过 max，必须发送
      combined_size >= max_chars ->
        state = send_blocks(state, [combined_text])
        %{state | coalesce_buffer: [], idle_timer: nil}

      # 达到 min，设置 idle timer
      combined_size >= min_chars ->
        timer = Process.send_after(self(), :coalesce_idle, idle_ms)
        %{state | coalesce_buffer: new_buffer, idle_timer: timer}

      # 不够 min，继续等待
      true ->
        timer = Process.send_after(self(), :coalesce_idle, idle_ms)
        %{state | coalesce_buffer: new_buffer, idle_timer: timer}
    end
  end

  # 刷新 coalesce buffer
  defp flush_coalesce_buffer(state) do
    if state.coalesce_buffer != [] do
      combined =
        Enum.join(state.coalesce_buffer, get_joiner(state.config.chunk[:break_preference]))

      state = send_blocks(state, [combined])
      %{state | coalesce_buffer: []}
    else
      state
    end
  end

  # 根据 break_preference 获取 joiner
  defp get_joiner(:paragraph), do: "\n\n"
  defp get_joiner(:newline), do: "\n"
  defp get_joiner(_), do: " "

  # 发送块
  defp send_blocks(state, []), do: state

  defp send_blocks(state, chunks) do
    Enum.reduce(chunks, state, fn chunk, acc ->
      if chunk != "" do
        # Human-like delay（第一块之后）
        if acc.blocks_sent > 0 do
          apply_human_delay(acc.config.human_delay)
        end

        # 广播块
        broadcast_block(acc, chunk)

        %{acc | blocks_sent: acc.blocks_sent + 1}
      else
        acc
      end
    end)
  end

  # 应用人性化延迟
  defp apply_human_delay(config) do
    case Keyword.get(config, :mode, :off) do
      :off ->
        :ok

      :natural ->
        delay = Enum.random(800..2500)
        Process.sleep(delay)

      :custom ->
        min_ms = Keyword.get(config, :min_ms, 500)
        max_ms = Keyword.get(config, :max_ms, 1500)
        delay = Enum.random(min_ms..max_ms)
        Process.sleep(delay)
    end
  end

  # 广播块到 Phoenix Channel
  defp broadcast_block(state, content) do
    Phoenix.PubSub.broadcast(
      ClawdEx.PubSub,
      "agent:#{state.session_id}",
      {:block_chunk, state.run_id, %{content: content, block_index: state.blocks_sent}}
    )

    Logger.debug(
      "Block streamer sent block ##{state.blocks_sent} (#{String.length(content)} chars)"
    )
  end
end
