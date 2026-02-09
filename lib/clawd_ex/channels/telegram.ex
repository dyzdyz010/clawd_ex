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

  # Telegram 消息长度限制
  @max_message_length 4000

  defp do_send_message(token, chat_id, content, opts) do
    chat_id = ensure_integer(chat_id)
    reply_to = Keyword.get(opts, :reply_to)

    # 分割长消息
    chunks = split_message(content, @max_message_length)

    # 发送每个分块
    results =
      Enum.with_index(chunks)
      |> Enum.map(fn {chunk, index} ->
        # 只有第一个分块使用 reply_to
        chunk_reply_to = if index == 0, do: reply_to, else: nil
        send_single_message(token, chat_id, chunk, chunk_reply_to)
      end)

    # 返回最后一个成功的结果，或第一个错误
    case Enum.find(results, &match?({:error, _}, &1)) do
      nil -> List.last(results)
      error -> error
    end
  end

  defp send_single_message(token, chat_id, content, reply_to) do
    params =
      [chat_id: chat_id, text: content, parse_mode: "Markdown"]
      |> maybe_add_reply_params(reply_to)

    case Telegram.Api.request(token, "sendMessage", params) do
      {:ok, message} ->
        {:ok, format_message(message)}

      {:error, description} when is_binary(description) ->
        # 如果是 Markdown 解析错误或消息太长，回退到纯文本
        if String.contains?(description, "entities") or
             String.contains?(description, "parse") or
             String.contains?(description, "too long") do
          Logger.warning("Markdown/length error, retrying as plain text: #{description}")
          send_plain_text(token, chat_id, content, reply_to)
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
          send_plain_text(token, chat_id, content, reply_to)
        else
          Logger.error("Telegram send failed: #{description}")
          {:error, description}
        end

      {:error, reason} ->
        Logger.error("Telegram send failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp send_plain_text(token, chat_id, content, reply_to) do
    params =
      [chat_id: chat_id, text: content]
      |> maybe_add_reply_params(reply_to)

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

    pid =
      spawn(fn ->
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
    reply_to = message.id

    # 启动或获取会话
    case SessionManager.start_session(
           session_key: session_key,
           agent_id: nil,
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

    # 订阅 agent 事件（接收中间消息段）
    if session_id do
      Phoenix.PubSub.subscribe(ClawdEx.PubSub, "agent:#{session_id}")
    end

    # 启动持续的 typing 指示器
    stop_typing = start_typing_indicator(chat_id)

    # 在后台 Task 中处理消息，以便能接收 PubSub 事件
    parent = self()
    ref = make_ref()

    task =
      Task.async(fn ->
        result = SessionWorker.send_message(session_key, message.content)
        send(parent, {:result, ref, result})
      end)

    # 接收循环：处理中间消息段和最终结果
    final_result = receive_loop(chat_id, reply_to, ref, nil)

    # 清理
    stop_typing.()
    Task.shutdown(task, :brutal_kill)

    if session_id do
      Phoenix.PubSub.unsubscribe(ClawdEx.PubSub, "agent:#{session_id}")
    end

    case final_result do
      {:ok, response} when is_binary(response) ->
        Logger.info(
          "Sending Telegram final response to #{chat_id}: #{String.slice(response, 0, 50)}..."
        )

        send_response_with_media(chat_id, response, reply_to: reply_to)
        :ok

      {:error, reason} ->
        Logger.error("Session error: #{inspect(reason)}")
        send_message(chat_id, "抱歉，处理消息时出错了。")
        {:error, reason}
    end
  end

  # 接收循环：处理中间消息段和等待最终结果
  # sent_tools_msg: 是否已发送工具执行消息（避免重复发送）
  defp receive_loop(chat_id, reply_to, ref, state) do
    state = state || %{sent_segment: false, sent_tools_msg: false}

    receive do
      # 收到消息段（工具调用前的文本）
      {:agent_segment, _run_id, content, %{continuing: true}} when content != "" ->
        # 发送中间消息
        Logger.info("Sending Telegram segment: #{String.slice(content, 0, 50)}...")
        send_response_with_media(chat_id, content, reply_to: reply_to)
        receive_loop(chat_id, reply_to, ref, %{state | sent_segment: true})

      # 收到工具开始执行事件
      {:agent_status, _run_id, :tools_start, %{tools: tools, count: count}}
      when not state.sent_tools_msg and not state.sent_segment ->
        # 只有在没有发送过 segment 时才发送工具状态
        tool_names = format_tool_names(tools)
        msg = "🔧 正在执行 #{count} 个工具：#{tool_names}..."
        Logger.info("Sending Telegram tools status: #{msg}")
        send_message(chat_id, msg)
        receive_loop(chat_id, reply_to, ref, %{state | sent_tools_msg: true})

      # 收到工具执行完成事件 - 发送执行结果摘要
      {:agent_status, _run_id, :tools_done, %{tools: tools, iteration: iteration}} ->
        # 格式化工具执行结果
        msg = format_tools_done_message(tools, iteration)
        Logger.info("Sending Telegram tools done: #{String.slice(msg, 0, 50)}...")
        send_message(chat_id, msg)
        # 重置状态，准备接收下一轮
        receive_loop(chat_id, reply_to, ref, %{state | sent_tools_msg: false, sent_segment: false})

      # 收到最终结果
      {:result, ^ref, result} ->
        result

      # 忽略其他 agent 事件
      {:agent_chunk, _run_id, _chunk} ->
        receive_loop(chat_id, reply_to, ref, state)

      {:agent_status, _run_id, _status, _details} ->
        receive_loop(chat_id, reply_to, ref, state)

      {:agent_segment, _run_id, _content, _opts} ->
        receive_loop(chat_id, reply_to, ref, state)
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
    # 同步轮询：完成当前请求后再发起下一次
    case poll_updates(state) do
      {:ok, new_offset} ->
        # 成功时立即发起下一次轮询（getUpdates 本身有 30 秒长轮询）
        send(self(), :poll)
        {:noreply, %{state | offset: new_offset}}

      {:error, {:conflict, _}} ->
        # Conflict 错误需要更长时间等待（其他实例可能还在运行）
        Logger.warning("Telegram conflict detected, waiting 30s before retry...")
        Process.send_after(self(), :poll, 30_000)
        {:noreply, state}

      {:error, _reason} ->
        # 其他错误延迟 5 秒重试
        Process.send_after(self(), :poll, 5000)
        {:noreply, state}
    end
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
    cond do
      # 处理文本消息
      message["text"] ->
        formatted = format_message(message)
        Task.start(fn -> handle_message(formatted) end)

      # 处理文档消息
      message["document"] ->
        Task.start(fn -> handle_document_message(message) end)

      # 处理图片消息
      message["photo"] ->
        Task.start(fn -> handle_photo_message(message) end)

      true ->
        :ok
    end
  end

  defp process_update(_), do: :ok

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
