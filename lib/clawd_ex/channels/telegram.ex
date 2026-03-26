defmodule ClawdEx.Channels.Telegram do
  @moduledoc """
  Telegram 渠道实现

  使用 visciang/telegram 库处理 Telegram Bot API 调用
  """
  @behaviour ClawdEx.Channels.Channel

  use GenServer
  require Logger

  alias ClawdEx.Sessions.{SessionManager, SessionWorker}
  alias ClawdEx.Security.GroupWhitelist
  alias ClawdEx.Security.DmPairing

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

  # Telegram 消息长度限制
  @max_message_length 4000

  defp do_send_message(token, chat_id, content, opts) do
    chat_id = ensure_integer(chat_id)
    reply_to = Keyword.get(opts, :reply_to)
    thread_id = Keyword.get(opts, :message_thread_id)

    # 分割长消息
    chunks = split_message(content, @max_message_length)

    # 发送每个分块
    results =
      Enum.with_index(chunks)
      |> Enum.map(fn {chunk, index} ->
        # 只有第一个分块使用 reply_to
        chunk_reply_to = if index == 0, do: reply_to, else: nil
        send_single_message(token, chat_id, chunk, chunk_reply_to, thread_id)
      end)

    # 返回最后一个成功的结果，或第一个错误
    case Enum.find(results, &match?({:error, _}, &1)) do
      nil -> List.last(results)
      error -> error
    end
  end

  defp send_single_message(token, chat_id, content, reply_to, thread_id) do
    params =
      [chat_id: chat_id, text: content, parse_mode: "Markdown"]
      |> maybe_add_reply_params(reply_to)
      |> maybe_add_thread_id(thread_id)

    case Telegram.Api.request(token, "sendMessage", params) do
      {:ok, message} ->
        {:ok, format_message(message)}

      {:error, description} when is_binary(description) ->
        # 如果是 Markdown 解析错误或消息太长，回退到纯文本
        if String.contains?(description, "entities") or
             String.contains?(description, "parse") or
             String.contains?(description, "too long") do
          Logger.warning("Markdown/length error, retrying as plain text: #{description}")
          send_plain_text(token, chat_id, content, reply_to, thread_id)
        else
          Logger.error("Telegram send failed: #{description}")
          {:error, description}
        end

      {:error, %{"description" => description}} ->
        # 处理 map 格式的错误（兼容性）
        if String.contains?(description, "entities") or
             String.contains?(description, "parse") or
             String.contains?(description, "too long") do
          Logger.warning("Markdown/length error, retrying as plain text: #{description}")
          send_plain_text(token, chat_id, content, reply_to, thread_id)
        else
          Logger.error("Telegram send failed: #{description}")
          {:error, description}
        end

      {:error, reason} ->
        Logger.error("Telegram send failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp send_plain_text(token, chat_id, content, reply_to, thread_id) do
    params =
      [chat_id: chat_id, text: content]
      |> maybe_add_reply_params(reply_to)
      |> maybe_add_thread_id(thread_id)

    case Telegram.Api.request(token, "sendMessage", params) do
      {:ok, message} ->
        {:ok, format_message(message)}

      {:error, %{"description" => description}} ->
        Logger.error("Telegram plain text send failed: #{description}")
        {:error, description}

      {:error, reason} ->
        Logger.error("Telegram plain text send failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # 分割长消息，尽量在段落边界分割
  defp split_message(content, max_length) when byte_size(content) <= max_length do
    [content]
  end

  defp split_message(content, max_length) do
    do_split_message(content, max_length, [])
  end

  defp do_split_message("", _max_length, acc), do: Enum.reverse(acc)

  defp do_split_message(content, max_length, acc) when byte_size(content) <= max_length do
    Enum.reverse([content | acc])
  end

  defp do_split_message(content, max_length, acc) do
    # 尝试在换行符处分割
    chunk = String.slice(content, 0, max_length)

    # 找到最后一个换行符位置
    split_pos =
      case :binary.match(String.reverse(chunk), "\n") do
        {pos, _} -> max_length - pos - 1
        :nomatch -> max_length
      end

    # 确保至少分割一些内容
    split_pos = max(split_pos, div(max_length, 2))

    {first, rest} = String.split_at(content, split_pos)
    do_split_message(String.trim_leading(rest), max_length, [String.trim_trailing(first) | acc])
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

    {:ok, pid} =
      Task.Supervisor.start_child(ClawdEx.AgentTaskSupervisor, fn ->
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
    reply_to = message.id

    # Extract group/topic routing info from metadata
    is_group = message.metadata[:is_group] || false
    is_private = !is_group
    topic_id = message.metadata[:topic_id]

    # Resolve agent and build session key
    {session_key, agent_id} =
      if is_private do
        # Private chat: keep legacy format, resolve via DM pairing
        user_id = message.metadata[:sender_id]
        agent_id = resolve_agent_for_dm(user_id)
        {"telegram:#{chat_id}", agent_id}
      else
        # Group/topic: resolve agent from message content and topic config
        agent_id = resolve_agent_for_group(message.content, chat_id, topic_id)
        {build_group_session_key(chat_id, topic_id, agent_id), agent_id}
      end

    # 立即发送 typing 状态 — 在任何 session 初始化之前
    stop_typing = start_typing_indicator(chat_id)

    # 启动或获取会话
    case SessionManager.start_session(
           session_key: session_key,
           agent_id: agent_id,
           channel: "telegram"
         ) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to start session: #{inspect(reason)}")
        :error
    end

    # 获取 session_id 用于订阅 PubSub
    session_id = get_session_id(session_key)

    # 订阅 output 事件（渐进式输出）和 agent 事件
    if session_id do
      Phoenix.PubSub.subscribe(ClawdEx.PubSub, "output:#{session_id}")
      Phoenix.PubSub.subscribe(ClawdEx.PubSub, "agent:#{session_id}")
    end

    # Build send opts for intermediate messages (segments, tool status)
    intermediate_send_opts = [reply_to: reply_to]
    intermediate_send_opts = if topic_id, do: Keyword.put(intermediate_send_opts, :message_thread_id, topic_id), else: intermediate_send_opts

    # 异步发送消息 — 不再同步等待整个 run 完成
    parent = self()
    ref = make_ref()

    task =
      Task.async(fn ->
        result = SessionWorker.send_message(session_key, message.content,
          inbound_metadata: message.metadata
        )
        send(parent, {:result, ref, result})
      end)

    # 接收循环：处理渐进式输出段和最终结果
    final_result = receive_loop(chat_id, intermediate_send_opts, ref, nil)

    # 清理
    stop_typing.()
    Task.shutdown(task, :brutal_kill)

    if session_id do
      Phoenix.PubSub.unsubscribe(ClawdEx.PubSub, "output:#{session_id}")
      Phoenix.PubSub.unsubscribe(ClawdEx.PubSub, "agent:#{session_id}")
    end

    # Build response opts with thread_id for topic replies
    response_opts = [reply_to: reply_to]
    response_opts = if topic_id, do: Keyword.put(response_opts, :message_thread_id, topic_id), else: response_opts

    case final_result do
      {:ok, response} when is_binary(response) ->
        # Parse reply tags from response
        {response, effective_reply_to} = parse_reply_tags(response, reply_to)
        response_opts = Keyword.put(response_opts, :reply_to, effective_reply_to)

        Logger.info(
          "Sending Telegram final response to #{chat_id}: #{String.slice(response, 0, 50)}..."
        )

        send_response_with_media(chat_id, response, response_opts)
        :ok

      {:error, reason} ->
        Logger.error("Session error: #{inspect(reason)}")
        error_msg = ClawdEx.Agent.Loop.friendly_error_message(reason)
        send_message(chat_id, "⚠️ #{error_msg}", response_opts)
        {:error, reason}
    end
  end

  # 接收循环：处理渐进式输出段和等待最终结果
  # sent_tools_msg: 是否已发送工具执行消息（避免重复发送）
  # send_opts: keyword list with :reply_to and optionally :message_thread_id for topic routing
  # verbose_tools: 是否显示工具调用状态（默认 false，减少刷屏）
  defp receive_loop(chat_id, send_opts, ref, state) do
    state = state || %{sent_segment: false, sent_tools_msg: false}
    verbose_tools = Application.get_env(:clawd_ex, :verbose_tool_output, false)

    receive do
      # OutputManager: 收到渐进式输出段（优先处理）
      {:output_segment, _run_id, content, metadata} when content != "" ->
        type = Map.get(metadata, :type, :intermediate)

        # progress 类型（Round N: ✓ Bash...）只在 verbose 模式发送
        if type == :progress and not verbose_tools do
          Logger.debug("Skipping Telegram progress segment (verbose_tools=false)")
          receive_loop(chat_id, send_opts, ref, state)
        else
          Logger.info("Sending Telegram output segment (#{type}): #{String.slice(content, 0, 50)}...")
          send_response_with_media(chat_id, content, send_opts)
          receive_loop(chat_id, send_opts, ref, %{state | sent_segment: true})
        end

      # OutputManager: 运行完成信号
      {:output_complete, _run_id, _final_content, _metadata} ->
        # Don't send here — the final result comes via {:result, ref, ...}
        # Just continue waiting for it
        receive_loop(chat_id, send_opts, ref, state)

      # Legacy: agent_segment is no longer used for intermediate text.
      # All intermediate output goes through OutputManager → {:output_segment, ...}
      # Keep this clause to drain any stale messages without sending duplicates.
      {:agent_segment, _run_id, _content, %{continuing: true}} ->
        receive_loop(chat_id, send_opts, ref, state)

      # 收到工具开始执行事件
      {:agent_status, _run_id, :tools_start, %{tools: tools, count: count}}
      when not state.sent_tools_msg and not state.sent_segment ->
        if verbose_tools do
          tool_names = format_tool_names(tools)
          msg = "🔧 正在执行 #{count} 个工具：#{tool_names}..."
          Logger.info("Sending Telegram tools status: #{msg}")
          send_message(chat_id, msg, send_opts)
        end
        receive_loop(chat_id, send_opts, ref, %{state | sent_tools_msg: true})

      # 收到工具执行完成事件 - 发送执行结果摘要
      {:agent_status, _run_id, :tools_done, %{tools: tools, iteration: iteration}} ->
        if verbose_tools do
          msg = format_tools_done_message(tools, iteration)
          Logger.info("Sending Telegram tools done: #{String.slice(msg, 0, 50)}...")
          send_message(chat_id, msg, send_opts)
        end
        # 重置状态，准备接收下一轮
        receive_loop(chat_id, send_opts, ref, %{state | sent_tools_msg: false, sent_segment: false})

      # 收到最终结果
      {:result, ^ref, result} ->
        result

      # 忽略其他 agent 事件
      {:agent_chunk, _run_id, _chunk} ->
        receive_loop(chat_id, send_opts, ref, state)

      {:agent_status, _run_id, _status, _details} ->
        receive_loop(chat_id, send_opts, ref, state)

      {:agent_segment, _run_id, _content, _opts} ->
        receive_loop(chat_id, send_opts, ref, state)
    after
      # 10 分钟超时
      600_000 ->
        {:error, :timeout}
    end
  end

  # 格式化工具名称列表
  defp format_tool_names(tools) when is_list(tools) do
    tools
    |> Enum.take(3)
    |> Enum.map(&humanize_tool_name/1)
    |> Enum.join("、")
    |> case do
      names when length(tools) > 3 -> names <> " 等"
      names -> names
    end
  end

  defp format_tool_names(_), do: "工具"

  defp humanize_tool_name("web_search"), do: "网页搜索"
  defp humanize_tool_name("web_fetch"), do: "网页获取"
  defp humanize_tool_name("exec"), do: "命令执行"
  defp humanize_tool_name("Read"), do: "读取文件"
  defp humanize_tool_name("Write"), do: "写入文件"
  defp humanize_tool_name("Edit"), do: "编辑文件"
  defp humanize_tool_name("browser"), do: "浏览器"
  defp humanize_tool_name("memory_search"), do: "记忆搜索"
  defp humanize_tool_name(name), do: name

  # 格式化工具执行完成消息
  defp format_tools_done_message(tools, iteration) do
    tool_results =
      tools
      |> Enum.map(fn %{tool: tool, result: result} ->
        tool_name = humanize_tool_name(tool)
        # 截断过长的结果
        short_result =
          if String.length(result) > 100 do
            String.slice(result, 0..97) <> "..."
          else
            result
          end
        "• #{tool_name}: #{short_result}"
      end)
      |> Enum.join("\n")

    if iteration > 0 do
      "✅ 第 #{iteration + 1} 轮工具执行完成:\n#{tool_results}"
    else
      "✅ 工具执行完成:\n#{tool_results}"
    end
  end

  defp get_session_id(session_key) do
    case ClawdEx.Repo.get_by(ClawdEx.Sessions.Session, session_key: session_key) do
      nil -> nil
      session -> session.id
    end
  end

  # 解析响应并发送，支持文本和媒体混合
  defp send_response_with_media(chat_id, response, opts) do
    # 查找所有图片路径：
    # 1. MEDIA: 标记的路径
    # 2. 绝对路径 /path/to/image.png
    # 3. URL https://...image.png
    media_paths = extract_media_paths(response)

    case media_paths do
      [] ->
        # 没有媒体，直接发送文本
        case send_message(chat_id, response, opts) do
          {:ok, _} -> Logger.info("Telegram message sent successfully")
          {:error, err} -> Logger.error("Telegram send failed: #{inspect(err)}")
        end

      paths ->
        # 有媒体文件，分别处理
        # 先发送去除媒体路径的文本（如果有的话）
        text_content = remove_media_paths(response, paths) |> String.trim()

        if text_content != "" do
          case send_message(chat_id, text_content, opts) do
            {:ok, _} -> Logger.info("Telegram text message sent")
            {:error, err} -> Logger.error("Telegram text send failed: #{inspect(err)}")
          end
        end

        # 发送所有媒体文件（只发送存在的文件）
        Enum.each(paths, fn path ->
          if File.exists?(path) or String.starts_with?(path, "http") do
            Logger.info("Sending media: #{path}")

            case send_photo(chat_id, path, opts) do
              {:ok, _} -> Logger.info("Telegram photo sent successfully: #{path}")
              {:error, err} -> Logger.error("Telegram photo send failed: #{inspect(err)}")
            end
          else
            Logger.warning("Media file not found: #{path}")
          end
        end)
    end
  end

  # 提取响应中的所有图片路径
  defp extract_media_paths(response) do
    # 匹配模式：
    # 1. MEDIA: /path/to/file.png
    # 2. 绝对路径 /xxx/xxx.png (支持各种包裹字符)
    # 3. URL https://xxx.png
    patterns = [
      # MEDIA: 标记
      ~r/MEDIA:\s*(\S+\.(?:png|jpg|jpeg|gif|webp))/i,
      # 绝对路径（以 / 开头，包含图片扩展名）
      # 支持被空格、反引号、引号、换行等包裹
      ~r/(?:^|[\s\n`'"*_\[（(])(\/[\w\-\.\/]+\.(?:png|jpg|jpeg|gif|webp))(?:[\s\n`'"*_\]）),]|$)/im,
      # HTTP(S) URL
      ~r/(https?:\/\/[^\s`'"<>]+\.(?:png|jpg|jpeg|gif|webp))/i
    ]

    paths =
      patterns
      |> Enum.flat_map(fn pattern ->
        Regex.scan(pattern, response)
        |> Enum.map(fn
          [_, path] -> String.trim(path)
          [path] -> String.trim(path)
        end)
      end)
      |> Enum.uniq()

    Logger.debug("Extracted media paths: #{inspect(paths)}")
    paths
  end

  # 从响应中移除媒体路径（避免显示原始路径）
  defp remove_media_paths(response, paths) do
    Enum.reduce(paths, response, fn path, acc ->
      # 移除 MEDIA: path 格式
      acc = Regex.replace(~r/MEDIA:\s*#{Regex.escape(path)}/i, acc, "")
      # 移除 "文件路径: path" 格式
      acc = Regex.replace(~r/文件路径[：:]\s*#{Regex.escape(path)}/i, acc, "[已发送图片]")
      acc
    end)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    case configure_token() do
      {:ok, token} ->
        # Clear any stale webhook/polling state
        Telegram.Api.request(token, "deleteWebhook", drop_pending_updates: false)

        case Telegram.Api.request(token, "getMe") do
          {:ok, bot_info} ->
            Logger.info("Telegram bot started: @#{bot_info["username"]}")
            # Register slash command menu with Telegram (fire-and-forget)
            Task.start(fn -> register_bot_commands() end)
            saved_offset = load_saved_offset()
            send(self(), :poll)
            {:ok, %__MODULE__{token: token, bot_info: bot_info, offset: saved_offset, running: true}}

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
    # 同步轮询：完成当前请求后再发起下一次
    case poll_updates(state) do
      {:ok, new_offset} ->
        save_offset(new_offset)
        # 成功时立即发起下一次轮询（getUpdates 本身有 30 秒长轮询）
        send(self(), :poll)
        {:noreply, %{state | offset: new_offset}}

      {:error, {:conflict, _}} ->
        # Conflict: another instance may still be polling, retry quickly
        Logger.warning("Telegram conflict detected, retrying in 5s...")
        Process.send_after(self(), :poll, 5_000)
        {:noreply, state}

      {:error, _reason} ->
        # 其他错误延迟 5 秒重试
        Process.send_after(self(), :poll, 5000)
        {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    if state.running do
      Logger.info("Telegram bot shutting down, saving offset #{state.offset}")
      save_offset(state.offset)
    end

    :ok
  end

  # Private Functions

  # --- Offset persistence ---

  defp offset_file do
    Path.join(System.get_env("HOME", "/tmp"), ".clawd/telegram_poll_offset")
  end

  defp load_saved_offset do
    case File.read(offset_file()) do
      {:ok, content} ->
        case Integer.parse(String.trim(content)) do
          {offset, _} ->
            Logger.info("Loaded saved Telegram poll offset: #{offset}")
            offset

          :error ->
            0
        end

      {:error, _} ->
        0
    end
  end

  defp save_offset(offset) when offset > 0 do
    File.mkdir_p!(Path.dirname(offset_file()))
    File.write!(offset_file(), Integer.to_string(offset))
  end

  defp save_offset(_), do: :ok

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
        {:ok, state.offset}

      {:ok, updates} ->
        Enum.each(updates, &process_update/1)

        new_offset =
          updates
          |> List.last()
          |> Map.get("update_id")
          |> Kernel.+(1)

        {:ok, new_offset}

      {:error, reason} ->
        # 检测是否是 Conflict 错误
        is_conflict =
          case reason do
            msg when is_binary(msg) -> String.contains?(msg, "Conflict")
            %{"description" => desc} -> String.contains?(desc, "Conflict")
            _ -> false
          end

        if is_conflict do
          Logger.warning("Telegram poll conflict: #{inspect(reason)}")
          {:error, {:conflict, reason}}
        else
          Logger.error("Telegram poll error: #{inspect(reason)}")
          {:error, reason}
        end
    end
  end

  defp process_update(%{"message" => message}) when not is_nil(message) do
    chat = message["chat"] || %{}
    chat_type = chat["type"] || "private"
    chat_id = to_string(chat["id"])
    from = message["from"] || %{}
    user_id = to_string(from["id"])
    text = message["text"] || ""

    is_group = chat_type in ["group", "supergroup"]
    is_private = chat_type == "private"

    cond do
      # --- Group whitelist check ---
      is_group and not group_allowed?(chat_id) ->
        Logger.debug("Message from non-whitelisted group #{chat_id}, silently dropping")
        :ok

      # --- DM pairing: handle /pair command ---
      is_private and String.starts_with?(text, "/pair ") ->
        code = text |> String.trim_leading("/pair ") |> String.trim()
        handle_pair_command(chat_id, user_id, code)

      # --- DM pairing: check if user is paired ---
      is_private and not dm_paired?(user_id) ->
        send_message(chat_id, "请先绑定一个 Agent，发送配对码：/pair <code>")
        :ok

      # --- Slash command handling ---
      ClawdEx.Commands.Handler.command?(text) ->
        topic_id = message["message_thread_id"]

        {session_key, agent_id} =
          if is_private do
            {"telegram:#{chat_id}", resolve_agent_for_dm(user_id)}
          else
            aid = resolve_agent_for_group(text, chat_id, topic_id)
            {build_group_session_key(chat_id, topic_id, aid), aid}
          end

        context = %{
          session_key: session_key,
          chat_id: chat_id,
          user_id: user_id,
          agent_id: agent_id
        }

        {:ok, response} = ClawdEx.Commands.Handler.handle(text, context)
        send_opts = if topic_id, do: [message_thread_id: topic_id], else: []
        send_message(chat_id, response, send_opts)

      # --- Normal message processing ---
      true ->
        cond do
          message["text"] ->
            formatted = format_message(message)
            Task.start(fn -> handle_message(formatted) end)

          message["document"] ->
            Task.start(fn -> handle_document_message(message) end)

          message["photo"] ->
            Task.start(fn -> handle_photo_message(message) end)

          true ->
            :ok
        end
    end
  end

  defp process_update(_), do: :ok

  # ============================================================================
  # Session Key Building & Agent Resolution
  # ============================================================================

  @doc false
  # Build session key for group chats (with optional topic isolation)
  # Private chats use the legacy format "telegram:{chat_id}" (handled separately)
  def build_group_session_key(chat_id, nil = _topic_id, agent_id) do
    "telegram:#{chat_id}:agent:#{agent_id}"
  end

  def build_group_session_key(chat_id, topic_id, agent_id) do
    "telegram:#{chat_id}:topic:#{topic_id}:agent:#{agent_id}"
  end

  @doc false
  # Resolve agent for DM (private chat) via DM pairing
  def resolve_agent_for_dm(user_id) do
    if dm_pairing_available?() do
      case DmPairing.Server.lookup(user_id, "telegram") do
        {:ok, agent_id} -> agent_id
        :not_paired -> nil
      end
    else
      nil
    end
  end

  @doc false
  # Resolve which agent should handle a group/topic message.
  #
  # Priority:
  # 1. Message starts with "@AgentName" → exact match
  # 2. Message text contains an agent name → fuzzy match (first match wins)
  # 3. Topic has a default agent configured via agent.config["default_topics"]
  # 4. Fallback to default agent (first active agent or id=1)
  def resolve_agent_for_group(content, chat_id, topic_id) do
    agents = list_active_agents()

    # 1. Try @mention at start of message (case-insensitive)
    case match_agent_mention(content, agents) do
      {:ok, agent_id} -> agent_id
      :no_match ->
        # 2. Try fuzzy name match anywhere in content
        case match_agent_in_text(content, agents) do
          {:ok, agent_id} -> agent_id
          :no_match ->
            # 3. Try topic default agent
            case find_topic_default_agent(chat_id, topic_id, agents) do
              {:ok, agent_id} -> agent_id
              :no_match ->
                # 4. Fallback to default agent
                get_default_agent_id(agents)
            end
        end
    end
  end

  # Match "@AgentName" at the start of message text
  defp match_agent_mention(content, agents) when is_binary(content) do
    trimmed = String.trim(content)

    Enum.find_value(agents, :no_match, fn agent ->
      name = agent.name
      # Check for "@Name" or "@ Name" at start (case-insensitive)
      pattern = ~r/^@\s*#{Regex.escape(name)}\b/iu

      if Regex.match?(pattern, trimmed) do
        {:ok, agent.id}
      end
    end)
  end

  defp match_agent_mention(_, _agents), do: :no_match

  # Match agent name anywhere in text (case-insensitive, word boundary)
  defp match_agent_in_text(content, agents) when is_binary(content) do
    Enum.find_value(agents, :no_match, fn agent ->
      name = agent.name
      # Word boundary match, case-insensitive
      pattern = ~r/\b#{Regex.escape(name)}\b/iu

      if Regex.match?(pattern, content) do
        {:ok, agent.id}
      end
    end)
  end

  defp match_agent_in_text(_, _agents), do: :no_match

  # Find an agent configured as the default for a specific topic
  # Looks in agent.config["default_topics"]["telegram:{chat_id}"] for topic_id
  defp find_topic_default_agent(_chat_id, nil, _agents), do: :no_match

  defp find_topic_default_agent(chat_id, topic_id, agents) do
    topic_key = "telegram:#{chat_id}"
    topic_id_int = to_integer(topic_id)

    Enum.find_value(agents, :no_match, fn agent ->
      default_topics = get_in(agent.config || %{}, ["default_topics"])

      # Support two formats:
      # 1. Map: {"telegram:-100xxx": [144, 145]}  — per-chat topic list
      # 2. List: [144, "144"]                      — simple topic list (matches any chat)
      topic_ids =
        case default_topics do
          map when is_map(map) -> Map.get(map, topic_key, [])
          list when is_list(list) -> list
          _ -> []
        end

      ids_as_int = Enum.map(topic_ids, &to_integer/1)

      if topic_id_int in ids_as_int do
        {:ok, agent.id}
      end
    end)
  end

  defp to_integer(v) when is_integer(v), do: v
  defp to_integer(v) when is_binary(v), do: String.to_integer(v)
  defp to_integer(v), do: v

  # Get the default agent (first active agent, or create one)
  defp get_default_agent_id([]), do: get_or_create_default_agent_id()
  defp get_default_agent_id([first | _]), do: first.id

  defp list_active_agents do
    import Ecto.Query

    ClawdEx.Agents.Agent
    |> where([a], a.active == true)
    |> order_by([a], asc: a.id)
    |> ClawdEx.Repo.all()
  rescue
    _ -> []
  end

  defp get_or_create_default_agent_id do
    alias ClawdEx.Agents.Agent

    case ClawdEx.Repo.get_by(Agent, name: "default") do
      nil ->
        case %Agent{} |> Agent.changeset(%{name: "default"}) |> ClawdEx.Repo.insert() do
          {:ok, agent} -> agent.id
          {:error, _} ->
            case ClawdEx.Repo.get_by(Agent, name: "default") do
              nil -> nil
              agent -> agent.id
            end
        end

      agent ->
        agent.id
    end
  rescue
    _ -> nil
  end

  # --- Bot command menu registration ---

  @doc false
  def register_bot_commands do
    token = get_token()

    if token do
      commands = [
        %{command: "new", description: "开始新对话"},
        %{command: "reset", description: "重置当前会话"},
        %{command: "status", description: "查看会话状态"},
        %{command: "model", description: "查看/切换 AI 模型"},
        %{command: "help", description: "显示帮助信息"},
        %{command: "compact", description: "压缩会话历史"},
        %{command: "version", description: "显示版本信息"}
      ]

      body = Jason.encode!(%{commands: commands})
      url = "https://api.telegram.org/bot#{token}/setMyCommands"

      case Req.post(url, body: body, headers: [{"content-type", "application/json"}]) do
        {:ok, %{status: 200}} ->
          Logger.info("Telegram bot commands registered successfully")
          :ok

        {:ok, resp} ->
          Logger.warning("Failed to register bot commands: #{inspect(resp.body)}")
          {:error, resp.body}

        {:error, reason} ->
          Logger.warning("Failed to register bot commands: #{inspect(reason)}")
          {:error, reason}
      end
    else
      :ok
    end
  end

  # --- Security helpers ---

  defp group_allowed?(group_id) do
    # Check all agents — if any agent allows this group, allow it.
    # If no agents have whitelist configured, allow all (backward compatible).
    case ClawdEx.Repo.all(ClawdEx.Agents.Agent) do
      [] ->
        true

      agents ->
        Enum.any?(agents, fn agent ->
          GroupWhitelist.check(agent, group_id) == :allow
        end)
    end
  rescue
    _ -> true
  end

  defp dm_paired?(user_id) do
    if dm_pairing_available?() do
      case DmPairing.Server.lookup(user_id, "telegram") do
        {:ok, _agent_id} -> true
        :not_paired -> false
      end
    else
      # DM pairing not available, allow all (backward compatible)
      true
    end
  end

  defp handle_pair_command(chat_id, user_id, code) do
    if dm_pairing_available?() do
      case DmPairing.Server.pair(user_id, "telegram", code) do
        {:ok, %{agent_name: name}} ->
          send_message(chat_id, "✅ 配对成功！已绑定到 Agent: #{name}")

        {:error, :invalid_code} ->
          send_message(chat_id, "❌ 无效的配对码，请检查后重试。")

        {:error, _reason} ->
          send_message(chat_id, "❌ 配对失败，请稍后重试。")
      end
    else
      send_message(chat_id, "配对服务暂不可用。")
    end
  end

  defp dm_pairing_available? do
    Process.whereis(DmPairing.Server) != nil
  end

  # 处理文档消息（PDF、文本文件等）
  defp handle_document_message(message) do
    document = message["document"]
    file_id = document["file_id"]
    file_name = document["file_name"] || "unknown"
    mime_type = document["mime_type"] || "application/octet-stream"
    caption = message["caption"] || ""

    Logger.info("Received document: #{file_name} (#{mime_type})")

    token = get_token()

    # 获取文件路径
    case Telegram.Api.request(token, "getFile", file_id: file_id) do
      {:ok, %{"file_path" => file_path}} ->
        # 下载文件
        file_url = "https://api.telegram.org/file/bot#{token}/#{file_path}"

        case download_file(file_url) do
          {:ok, file_content} ->
            # 提取文本内容
            text_content = extract_file_content(file_content, mime_type, file_name)

            # 构建消息内容
            content =
              if caption != "" do
                "#{caption}\n\n[文件: #{file_name}]\n#{text_content}"
              else
                "[文件: #{file_name}]\n#{text_content}"
              end

            formatted = format_message(message) |> Map.put(:content, content)
            handle_message(formatted)

          {:error, reason} ->
            Logger.error("Failed to download file: #{inspect(reason)}")
            chat_id = to_string(message["chat"]["id"])
            send_message(chat_id, "抱歉，无法下载文件。")
        end

      {:error, reason} ->
        Logger.error("Failed to get file path: #{inspect(reason)}")
        chat_id = to_string(message["chat"]["id"])
        send_message(chat_id, "抱歉，无法获取文件信息。")
    end
  end

  # 处理图片消息
  defp handle_photo_message(message) do
    # 获取最大尺寸的图片
    photos = message["photo"]
    largest = Enum.max_by(photos, & &1["file_size"])
    file_id = largest["file_id"]
    caption = message["caption"] || "请查看这张图片"

    Logger.info("Received photo")

    token = get_token()

    case Telegram.Api.request(token, "getFile", file_id: file_id) do
      {:ok, %{"file_path" => file_path}} ->
        file_url = "https://api.telegram.org/file/bot#{token}/#{file_path}"

        # 构建消息，包含图片 URL 供 AI 分析
        content = "#{caption}\n\n[图片: #{file_url}]"

        formatted = format_message(message) |> Map.put(:content, content)
        handle_message(formatted)

      {:error, reason} ->
        Logger.error("Failed to get photo file path: #{inspect(reason)}")
        chat_id = to_string(message["chat"]["id"])
        send_message(chat_id, "抱歉，无法获取图片。")
    end
  end

  # 下载文件
  defp download_file(url) do
    case Req.get(url, receive_timeout: 60_000) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # 提取文件内容
  defp extract_file_content(content, mime_type, file_name) do
    cond do
      # PDF 文件
      String.contains?(mime_type, "pdf") or String.ends_with?(file_name, ".pdf") ->
        extract_pdf_text(content)

      # 文本文件
      String.starts_with?(mime_type, "text/") or
        String.ends_with?(file_name, [".txt", ".md", ".json", ".xml", ".csv", ".log"]) ->
        content
        |> :unicode.characters_to_binary(:utf8)
        |> case do
          {:error, _, _} -> "[无法解码文本内容]"
          {:incomplete, partial, _} -> partial
          text when is_binary(text) -> text
        end

      # 其他文件类型
      true ->
        "[不支持的文件类型: #{mime_type}]"
    end
  end

  # 使用 pdftotext 提取 PDF 文本
  defp extract_pdf_text(pdf_content) do
    # 写入临时文件
    tmp_path = "/tmp/clawd_ex_pdf_#{:erlang.unique_integer([:positive])}.pdf"

    try do
      File.write!(tmp_path, pdf_content)

      case System.cmd("pdftotext", [tmp_path, "-"], stderr_to_stdout: true) do
        {text, 0} ->
          String.trim(text)

        {error, _code} ->
          Logger.warning("pdftotext failed: #{error}")
          "[PDF 文本提取失败]"
      end
    rescue
      e ->
        Logger.error("PDF extraction error: #{inspect(e)}")
        "[PDF 处理出错]"
    after
      File.rm(tmp_path)
    end
  end

  defp format_message(message) do
    from = message["from"] || %{}
    chat = message["chat"] || %{}
    chat_type = chat["type"] || "private"
    is_group = chat_type in ["group", "supergroup"]
    is_forum = chat["is_forum"] == true

    %{
      id: to_string(message["message_id"]),
      content: message["text"] || "",
      author_id: to_string(from["id"]),
      author_name: build_display_name(from),
      channel_id: to_string(chat["id"]),
      timestamp: DateTime.from_unix!(message["date"] || 0),
      metadata: %{
        chat_type: chat_type,
        is_group: is_group,
        is_forum: is_forum,
        topic_id: message["message_thread_id"],
        username: from["username"],
        sender_id: to_string(from["id"]),
        sender_name: build_display_name(from),
        sender_username: from["username"],
        group_subject: chat["title"],
        reply_to_message_id: get_in(message, ["reply_to_message", "message_id"]),
        channel: "telegram"
      }
    }
  end

  defp build_display_name(from) do
    first = from["first_name"] || ""
    last = from["last_name"] || ""
    String.trim("#{first} #{last}")
  end

  # Parse reply tags like [[reply_to_current]] or [[reply_to:<id>]]
  defp parse_reply_tags(response, current_reply_to) do
    cond do
      # [[reply_to_current]] — reply to the triggering message
      String.starts_with?(response, "[[reply_to_current]]") ->
        cleaned = String.replace_prefix(response, "[[reply_to_current]]", "") |> String.trim_leading()
        {cleaned, current_reply_to}

      # [[reply_to:<id>]] — reply to a specific message
      Regex.match?(~r/^\[\[\s*reply_to:\s*(\d+)\s*\]\]/, response) ->
        case Regex.run(~r/^\[\[\s*reply_to:\s*(\d+)\s*\]\]/, response) do
          [full_match, msg_id] ->
            cleaned = String.replace_prefix(response, full_match, "") |> String.trim_leading()
            {cleaned, msg_id}

          _ ->
            {response, current_reply_to}
        end

      # No reply tag
      true ->
        {response, current_reply_to}
    end
  end

  defp ensure_integer(value) when is_integer(value), do: value
  defp ensure_integer(value) when is_binary(value), do: String.to_integer(value)

  defp maybe_add_reply_params(params, nil), do: params

  defp maybe_add_reply_params(params, reply_id) do
    reply_params = %{message_id: ensure_integer(reply_id)}
    Keyword.put(params, :reply_parameters, {:json, reply_params})
  end

  defp maybe_add_thread_id(params, nil), do: params

  defp maybe_add_thread_id(params, thread_id) do
    Keyword.put(params, :message_thread_id, ensure_integer(thread_id))
  end
end
