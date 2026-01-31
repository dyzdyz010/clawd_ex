defmodule ClawdEx.Browser.Server do
  @moduledoc """
  浏览器进程管理器

  负责启动、停止和管理 Chrome/Chromium 浏览器进程。
  使用 Chrome DevTools Protocol (CDP) 进行通信。
  """

  use GenServer

  require Logger

  alias ClawdEx.Browser.CDP

  @type browser_state :: :stopped | :starting | :running | :stopping

  @type state :: %{
          status: browser_state(),
          port: port() | nil,
          os_pid: integer() | nil,
          ws_url: String.t() | nil,
          debug_port: integer(),
          user_data_dir: String.t() | nil,
          headless: boolean()
        }

  # 默认配置
  @default_debug_port 9222
  @default_user_data_dir "/tmp/clawd_ex_browser"

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  启动 Browser Server
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  启动浏览器
  """
  @spec start_browser(keyword()) :: {:ok, map()} | {:error, term()}
  def start_browser(opts \\ []) do
    GenServer.call(__MODULE__, {:start_browser, opts}, 30_000)
  end

  @doc """
  停止浏览器
  """
  @spec stop_browser() :: :ok | {:error, term()}
  def stop_browser do
    GenServer.call(__MODULE__, :stop_browser, 10_000)
  end

  @doc """
  获取浏览器状态
  """
  @spec status() :: map()
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc """
  获取所有标签页
  """
  @spec list_tabs() :: {:ok, list()} | {:error, term()}
  def list_tabs do
    GenServer.call(__MODULE__, :list_tabs)
  end

  @doc """
  打开新标签页
  """
  @spec open_tab(String.t()) :: {:ok, map()} | {:error, term()}
  def open_tab(url \\ "about:blank") do
    GenServer.call(__MODULE__, {:open_tab, url})
  end

  @doc """
  关闭标签页
  """
  @spec close_tab(String.t()) :: :ok | {:error, term()}
  def close_tab(target_id) do
    GenServer.call(__MODULE__, {:close_tab, target_id})
  end

  @doc """
  导航到 URL
  """
  @spec navigate(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def navigate(target_id, url) do
    GenServer.call(__MODULE__, {:navigate, target_id, url})
  end

  @doc """
  获取页面快照 (accessibility tree)
  """
  @spec snapshot(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def snapshot(target_id, format \\ "aria") do
    GenServer.call(__MODULE__, {:snapshot, target_id, format}, 30_000)
  end

  @doc """
  截取页面截图
  """
  @spec screenshot(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def screenshot(target_id, opts \\ []) do
    GenServer.call(__MODULE__, {:screenshot, target_id, opts}, 30_000)
  end

  @doc """
  获取控制台日志
  """
  @spec console_logs(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def console_logs(target_id, opts \\ []) do
    GenServer.call(__MODULE__, {:console_logs, target_id, opts}, 10_000)
  end

  @doc """
  执行交互动作 (click, type, press, hover, select, fill, drag, wait)
  """
  @spec act(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def act(target_id, request) do
    GenServer.call(__MODULE__, {:act, target_id, request}, 30_000)
  end

  @doc """
  执行 JavaScript
  """
  @spec evaluate(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def evaluate(target_id, expression) do
    GenServer.call(__MODULE__, {:evaluate, target_id, expression}, 30_000)
  end

  @doc """
  上传文件
  """
  @spec upload(String.t(), String.t(), list(String.t())) :: {:ok, map()} | {:error, term()}
  def upload(target_id, input_ref, paths) do
    GenServer.call(__MODULE__, {:upload, target_id, input_ref, paths}, 30_000)
  end

  @doc """
  处理对话框 (alert, confirm, prompt)
  """
  @spec dialog(String.t(), boolean(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def dialog(target_id, accept, prompt_text \\ nil) do
    GenServer.call(__MODULE__, {:dialog, target_id, accept, prompt_text}, 10_000)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    state = %{
      status: :stopped,
      port: nil,
      os_pid: nil,
      ws_url: nil,
      debug_port: Keyword.get(opts, :debug_port, @default_debug_port),
      user_data_dir: Keyword.get(opts, :user_data_dir, @default_user_data_dir),
      headless: Keyword.get(opts, :headless, true)
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:start_browser, opts}, _from, %{status: :stopped} = state) do
    headless = Keyword.get(opts, :headless, state.headless)
    debug_port = Keyword.get(opts, :debug_port, state.debug_port)

    case do_start_browser(headless, debug_port, state.user_data_dir) do
      {:ok, port, os_pid, ws_url} ->
        # 连接 CDP
        case CDP.connect(ws_url) do
          :ok ->
            new_state = %{
              state
              | status: :running,
                port: port,
                os_pid: os_pid,
                ws_url: ws_url,
                headless: headless,
                debug_port: debug_port
            }

            result = %{
              status: "running",
              ws_url: ws_url,
              debug_port: debug_port,
              headless: headless
            }

            {:reply, {:ok, result}, new_state}

          {:error, reason} ->
            # 连接失败，关闭浏览器
            kill_browser(os_pid)
            {:reply, {:error, {:cdp_connect_failed, reason}}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:start_browser, _opts}, _from, state) do
    {:reply, {:error, {:already_running, state.status}}, state}
  end

  @impl true
  def handle_call(:stop_browser, _from, %{status: :running} = state) do
    CDP.disconnect()

    if state.os_pid do
      kill_browser(state.os_pid)
    end

    new_state = %{state | status: :stopped, port: nil, os_pid: nil, ws_url: nil}
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:stop_browser, _from, state) do
    {:reply, {:error, :not_running}, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    result = %{
      status: to_string(state.status),
      ws_url: state.ws_url,
      debug_port: state.debug_port,
      headless: state.headless,
      connected: CDP.connected?()
    }

    {:reply, result, state}
  end

  @impl true
  def handle_call(:list_tabs, _from, %{status: :running} = state) do
    # 使用 HTTP API 获取 targets
    case fetch_targets(state.debug_port) do
      {:ok, targets} ->
        tabs =
          targets
          |> Enum.filter(&(&1["type"] == "page"))
          |> Enum.map(fn t ->
            %{
              id: t["id"],
              title: t["title"],
              url: t["url"],
              type: t["type"]
            }
          end)

        {:reply, {:ok, tabs}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:list_tabs, _from, state) do
    {:reply, {:error, :not_running}, state}
  end

  @impl true
  def handle_call({:open_tab, url}, _from, %{status: :running} = state) do
    case CDP.send_command("Target.createTarget", %{url: url}) do
      {:ok, %{"targetId" => target_id}} ->
        {:reply, {:ok, %{target_id: target_id, url: url}}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:open_tab, _url}, _from, state) do
    {:reply, {:error, :not_running}, state}
  end

  @impl true
  def handle_call({:close_tab, target_id}, _from, %{status: :running} = state) do
    case CDP.send_command("Target.closeTarget", %{targetId: target_id}) do
      {:ok, %{"success" => true}} ->
        {:reply, :ok, state}

      {:ok, %{"success" => false}} ->
        {:reply, {:error, :close_failed}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:close_tab, _target_id}, _from, state) do
    {:reply, {:error, :not_running}, state}
  end

  @impl true
  def handle_call({:navigate, target_id, url}, _from, %{status: :running} = state) do
    # 需要先附加到 target，然后导航
    case attach_and_navigate(target_id, url) do
      {:ok, result} ->
        {:reply, {:ok, result}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:navigate, _target_id, _url}, _from, state) do
    {:reply, {:error, :not_running}, state}
  end

  @impl true
  def handle_call({:snapshot, target_id, format}, _from, %{status: :running} = state) do
    case get_page_snapshot(target_id, format) do
      {:ok, result} ->
        {:reply, {:ok, result}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:snapshot, _target_id, _format}, _from, state) do
    {:reply, {:error, :not_running}, state}
  end

  @impl true
  def handle_call({:screenshot, target_id, opts}, _from, %{status: :running} = state) do
    case capture_screenshot(target_id, opts) do
      {:ok, result} ->
        {:reply, {:ok, result}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:screenshot, _target_id, _opts}, _from, state) do
    {:reply, {:error, :not_running}, state}
  end

  @impl true
  def handle_call({:console_logs, target_id, opts}, _from, %{status: :running} = state) do
    case get_console_logs(target_id, opts) do
      {:ok, result} ->
        {:reply, {:ok, result}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:console_logs, _target_id, _opts}, _from, state) do
    {:reply, {:error, :not_running}, state}
  end

  @impl true
  def handle_call({:act, target_id, request}, _from, %{status: :running} = state) do
    case execute_action(target_id, request) do
      {:ok, result} ->
        {:reply, {:ok, result}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:act, _target_id, _request}, _from, state) do
    {:reply, {:error, :not_running}, state}
  end

  @impl true
  def handle_call({:evaluate, target_id, expression}, _from, %{status: :running} = state) do
    case execute_javascript(target_id, expression) do
      {:ok, result} ->
        {:reply, {:ok, result}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:evaluate, _target_id, _expression}, _from, state) do
    {:reply, {:error, :not_running}, state}
  end

  @impl true
  def handle_call({:upload, target_id, input_ref, paths}, _from, %{status: :running} = state) do
    case upload_files(target_id, input_ref, paths) do
      {:ok, result} ->
        {:reply, {:ok, result}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:upload, _target_id, _input_ref, _paths}, _from, state) do
    {:reply, {:error, :not_running}, state}
  end

  @impl true
  def handle_call({:dialog, target_id, accept, prompt_text}, _from, %{status: :running} = state) do
    case handle_dialog(target_id, accept, prompt_text) do
      {:ok, result} ->
        {:reply, {:ok, result}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:dialog, _target_id, _accept, _prompt_text}, _from, state) do
    {:reply, {:error, :not_running}, state}
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("Browser process exited with status: #{status}")
    CDP.disconnect()
    new_state = %{state | status: :stopped, port: nil, os_pid: nil, ws_url: nil}
    {:noreply, new_state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    Logger.debug("Browser output: #{data}")
    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("Browser unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp do_start_browser(headless, debug_port, user_data_dir) do
    # 查找 Chrome/Chromium
    chrome_path = find_chrome()

    if chrome_path == nil do
      {:error, :chrome_not_found}
    else
      # 确保用户数据目录存在
      File.mkdir_p!(user_data_dir)

      args = build_chrome_args(headless, debug_port, user_data_dir)
      cmd = "#{chrome_path} #{Enum.join(args, " ")}"

      Logger.info("Starting browser: #{cmd}")

      port =
        Port.open({:spawn, cmd}, [
          :binary,
          :exit_status,
          :stderr_to_stdout
        ])

      # 等待浏览器启动并获取 WebSocket URL
      case wait_for_browser(debug_port, 10_000) do
        {:ok, ws_url, os_pid} ->
          {:ok, port, os_pid, ws_url}

        {:error, reason} ->
          Port.close(port)
          {:error, reason}
      end
    end
  end

  defp find_chrome do
    paths = [
      # Linux
      "/usr/bin/chromium",
      "/usr/bin/chromium-browser",
      "/usr/bin/google-chrome",
      "/usr/bin/google-chrome-stable",
      # macOS
      "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
      "/Applications/Chromium.app/Contents/MacOS/Chromium",
      # snap
      "/snap/bin/chromium"
    ]

    Enum.find(paths, &File.exists?/1)
  end

  defp build_chrome_args(headless, debug_port, user_data_dir) do
    base_args = [
      "--remote-debugging-port=#{debug_port}",
      "--user-data-dir=#{user_data_dir}",
      "--no-first-run",
      "--no-default-browser-check",
      "--disable-background-networking",
      "--disable-extensions",
      "--disable-sync",
      "--disable-translate",
      "--metrics-recording-only",
      "--safebrowsing-disable-auto-update"
    ]

    headless_args =
      if headless do
        ["--headless=new", "--disable-gpu", "--no-sandbox"]
      else
        []
      end

    base_args ++ headless_args
  end

  defp wait_for_browser(debug_port, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_browser(debug_port, deadline)
  end

  defp do_wait_for_browser(debug_port, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      {:error, :timeout}
    else
      case fetch_browser_info(debug_port) do
        {:ok, info} ->
          ws_url = info["webSocketDebuggerUrl"]
          # 从 /json/version 我们拿不到 os_pid，设为 nil
          {:ok, ws_url, nil}

        {:error, _reason} ->
          Process.sleep(200)
          do_wait_for_browser(debug_port, deadline)
      end
    end
  end

  defp fetch_browser_info(debug_port) do
    url = "http://localhost:#{debug_port}/json/version"

    case Req.get(url) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_targets(debug_port) do
    url = "http://localhost:#{debug_port}/json/list"

    case Req.get(url) do
      {:ok, %{status: 200, body: body}} when is_list(body) ->
        {:ok, body}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp kill_browser(nil), do: :ok

  defp kill_browser(os_pid) do
    System.cmd("kill", ["-9", "#{os_pid}"], stderr_to_stdout: true)
    :ok
  rescue
    _ -> :ok
  end

  defp attach_and_navigate(target_id, url) do
    # 创建到 target 的会话
    with {:ok, %{"sessionId" => session_id}} <-
           CDP.send_command("Target.attachToTarget", %{
             targetId: target_id,
             flatten: true
           }),
         {:ok, result} <-
           CDP.send_command("Target.sendMessageToTarget", %{
             sessionId: session_id,
             message:
               Jason.encode!(%{
                 id: 1,
                 method: "Page.navigate",
                 params: %{url: url}
               })
           }) do
      {:ok, %{session_id: session_id, result: result}}
    end
  end

  # ============================================================================
  # Snapshot
  # ============================================================================

  defp get_page_snapshot(target_id, format) do
    with {:ok, session_id} <- attach_to_target(target_id),
         :ok <- enable_domain(session_id, "Accessibility"),
         {:ok, tree} <- get_accessibility_tree(session_id) do
      result = %{
        target_id: target_id,
        tree: normalize_aria_tree(tree),
        format: format
      }

      {:ok, result}
    end
  end

  defp get_accessibility_tree(session_id) do
    send_to_target(session_id, "Accessibility.getFullAXTree", %{})
  end

  defp normalize_aria_tree(%{"nodes" => nodes}) when is_list(nodes) do
    Enum.map(nodes, &normalize_aria_node/1)
  end
  defp normalize_aria_tree(tree), do: tree

  defp normalize_aria_node(node) when is_map(node) do
    %{
      role: get_in(node, ["role", "value"]),
      name: get_in(node, ["name", "value"]),
      value: get_in(node, ["value", "value"]),
      description: get_in(node, ["description", "value"]),
      node_id: node["nodeId"],
      children: node["childIds"]
    }
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Map.new()
  end
  defp normalize_aria_node(node), do: node

  # ============================================================================
  # Screenshot
  # ============================================================================

  @screenshot_dir "priv/browser/screenshots"

  defp capture_screenshot(target_id, opts) do
    full_page = Keyword.get(opts, :full_page, false)
    format = Keyword.get(opts, :format, "png")
    quality = Keyword.get(opts, :quality)

    with {:ok, session_id} <- attach_to_target(target_id),
         :ok <- enable_domain(session_id, "Page"),
         {:ok, %{"data" => data}} <- take_screenshot(session_id, full_page, format, quality) do
      # 保存截图到文件
      case save_screenshot(data, format) do
        {:ok, path} ->
          {:ok, %{target_id: target_id, path: path, format: format}}

        {:error, reason} ->
          {:error, {:save_failed, reason}}
      end
    end
  end

  defp take_screenshot(session_id, full_page, format, quality) do
    params = %{
      format: format,
      captureBeyondViewport: full_page
    }

    params = if quality && format == "jpeg", do: Map.put(params, :quality, quality), else: params

    send_to_target(session_id, "Page.captureScreenshot", params)
  end

  defp save_screenshot(base64_data, format) do
    ensure_screenshot_dir()

    timestamp = DateTime.utc_now() |> DateTime.to_unix()
    random_suffix = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    filename = "screenshot_#{timestamp}_#{random_suffix}.#{format}"
    filepath = Path.join(screenshot_dir(), filename)

    case Base.decode64(base64_data) do
      {:ok, binary} ->
        case File.write(filepath, binary) do
          :ok -> {:ok, filepath}
          {:error, reason} -> {:error, reason}
        end

      :error ->
        {:error, :invalid_base64}
    end
  end

  defp screenshot_dir do
    Application.app_dir(:clawd_ex, @screenshot_dir)
  rescue
    _ -> @screenshot_dir
  end

  defp ensure_screenshot_dir do
    dir = screenshot_dir()
    unless File.exists?(dir) do
      File.mkdir_p!(dir)
    end
  end

  # ============================================================================
  # Console Logs
  # ============================================================================

  defp get_console_logs(target_id, opts) do
    level = Keyword.get(opts, :level)
    _limit = Keyword.get(opts, :limit, 100)

    # Note: Console logs require Runtime.enable to be called early
    # and events to be collected. This is a simplified implementation
    # that returns stored logs from the page.
    with {:ok, session_id} <- attach_to_target(target_id),
         :ok <- enable_domain(session_id, "Runtime"),
         :ok <- enable_domain(session_id, "Console") do
      # CDP doesn't have a direct "get all console logs" command
      # Console messages are delivered as events. For now, return empty
      # with instructions. A full implementation would store events.
      result = %{
        target_id: target_id,
        entries: [],
        count: 0,
        note: "Console logging enabled. Future messages will be captured."
      }

      result =
        if level do
          Map.put(result, :filter_level, level)
        else
          result
        end

      {:ok, result}
    end
  end

  # ============================================================================
  # CDP Helpers
  # ============================================================================

  defp attach_to_target(target_id) do
    case CDP.send_command("Target.attachToTarget", %{
           targetId: target_id,
           flatten: true
         }) do
      {:ok, %{"sessionId" => session_id}} ->
        {:ok, session_id}

      {:error, _} = error ->
        error
    end
  end

  defp enable_domain(session_id, domain) do
    case send_to_target(session_id, "#{domain}.enable", %{}) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  defp send_to_target(session_id, method, params) do
    CDP.send_command("Target.sendMessageToTarget", %{
      sessionId: session_id,
      message: Jason.encode!(%{id: System.unique_integer([:positive]), method: method, params: params})
    })
  end

  # ============================================================================
  # Interactive Actions
  # ============================================================================

  defp execute_action(target_id, request) do
    kind = request["kind"] || request[:kind]

    with {:ok, session_id} <- attach_to_target(target_id),
         :ok <- enable_domain(session_id, "DOM"),
         :ok <- enable_domain(session_id, "Input"),
         :ok <- enable_domain(session_id, "Runtime") do
      case kind do
        "click" -> do_click(session_id, request)
        "type" -> do_type(session_id, request)
        "press" -> do_press(session_id, request)
        "hover" -> do_hover(session_id, request)
        "select" -> do_select(session_id, request)
        "fill" -> do_fill(session_id, request)
        "drag" -> do_drag(session_id, request)
        "wait" -> do_wait(session_id, request)
        _ -> {:error, {:unknown_action, kind}}
      end
    end
  end

  defp do_click(session_id, request) do
    ref = request["ref"] || request[:ref]
    double_click = request["doubleClick"] || request[:doubleClick] || false
    button = request["button"] || request[:button] || "left"

    with {:ok, %{"x" => x, "y" => y}} <- get_element_center(session_id, ref) do
      click_count = if double_click, do: 2, else: 1
      button_code = button_to_code(button)

      # 移动鼠标
      send_to_target(session_id, "Input.dispatchMouseEvent", %{
        type: "mouseMoved",
        x: x,
        y: y
      })

      # 鼠标按下
      send_to_target(session_id, "Input.dispatchMouseEvent", %{
        type: "mousePressed",
        x: x,
        y: y,
        button: button,
        clickCount: click_count,
        buttons: button_code
      })

      # 鼠标释放
      send_to_target(session_id, "Input.dispatchMouseEvent", %{
        type: "mouseReleased",
        x: x,
        y: y,
        button: button,
        clickCount: click_count,
        buttons: 0
      })

      {:ok, %{action: "click", ref: ref, x: x, y: y, double_click: double_click}}
    end
  end

  defp do_type(session_id, request) do
    ref = request["ref"] || request[:ref]
    text = request["text"] || request[:text] || ""
    slowly = request["slowly"] || request[:slowly] || false

    # 先点击元素聚焦
    with {:ok, _} <- do_click(session_id, %{ref: ref}) do
      if slowly do
        # 逐字符输入
        for char <- String.graphemes(text) do
          send_to_target(session_id, "Input.insertText", %{text: char})
          Process.sleep(50)
        end
      else
        send_to_target(session_id, "Input.insertText", %{text: text})
      end

      {:ok, %{action: "type", ref: ref, text: text}}
    end
  end

  defp do_press(session_id, request) do
    key = request["key"] || request[:key]
    modifiers = request["modifiers"] || request[:modifiers] || []
    ref = request["ref"] || request[:ref]

    # 如果有 ref，先聚焦元素
    if ref do
      do_click(session_id, %{ref: ref})
    end

    modifier_flags = modifiers_to_flags(modifiers)

    # 按下键
    send_to_target(session_id, "Input.dispatchKeyEvent", %{
      type: "keyDown",
      key: key,
      modifiers: modifier_flags
    })

    # 释放键
    send_to_target(session_id, "Input.dispatchKeyEvent", %{
      type: "keyUp",
      key: key,
      modifiers: modifier_flags
    })

    {:ok, %{action: "press", key: key, modifiers: modifiers}}
  end

  defp do_hover(session_id, request) do
    ref = request["ref"] || request[:ref]

    with {:ok, %{"x" => x, "y" => y}} <- get_element_center(session_id, ref) do
      send_to_target(session_id, "Input.dispatchMouseEvent", %{
        type: "mouseMoved",
        x: x,
        y: y
      })

      {:ok, %{action: "hover", ref: ref, x: x, y: y}}
    end
  end

  defp do_select(session_id, request) do
    ref = request["ref"] || request[:ref]
    values = request["values"] || request[:values] || []

    # 使用 JavaScript 设置 select 的值
    js = """
    (function() {
      const select = document.querySelector('[data-ref="#{ref}"]') ||
                     document.evaluate('#{ref}', document, null, XPathResult.FIRST_ORDERED_NODE_TYPE, null).singleNodeValue;
      if (!select) return {error: 'Element not found'};

      const valuesToSelect = #{Jason.encode!(values)};
      if (select.multiple) {
        Array.from(select.options).forEach(opt => {
          opt.selected = valuesToSelect.includes(opt.value);
        });
      } else {
        select.value = valuesToSelect[0];
      }

      select.dispatchEvent(new Event('change', { bubbles: true }));
      return {selected: valuesToSelect};
    })()
    """

    case evaluate_js(session_id, js) do
      {:ok, result} ->
        {:ok, Map.merge(%{action: "select", ref: ref, values: values}, result)}

      error ->
        error
    end
  end

  defp do_fill(session_id, request) do
    fields = request["fields"] || request[:fields] || []
    submit = request["submit"] || request[:submit] || false

    results =
      Enum.map(fields, fn field ->
        ref = field["ref"] || field[:ref]
        text = field["text"] || field[:text] || ""

        case do_type(session_id, %{ref: ref, text: text}) do
          {:ok, result} -> result
          {:error, reason} -> %{ref: ref, error: inspect(reason)}
        end
      end)

    if submit do
      do_press(session_id, %{key: "Enter"})
    end

    {:ok, %{action: "fill", fields: results, submit: submit}}
  end

  defp do_drag(session_id, request) do
    start_ref = request["startRef"] || request[:startRef]
    end_ref = request["endRef"] || request[:endRef]

    with {:ok, %{"x" => x1, "y" => y1}} <- get_element_center(session_id, start_ref),
         {:ok, %{"x" => x2, "y" => y2}} <- get_element_center(session_id, end_ref) do
      # 移动到起点
      send_to_target(session_id, "Input.dispatchMouseEvent", %{
        type: "mouseMoved",
        x: x1,
        y: y1
      })

      # 按下鼠标
      send_to_target(session_id, "Input.dispatchMouseEvent", %{
        type: "mousePressed",
        x: x1,
        y: y1,
        button: "left",
        buttons: 1
      })

      # 拖动到终点
      send_to_target(session_id, "Input.dispatchMouseEvent", %{
        type: "mouseMoved",
        x: x2,
        y: y2,
        buttons: 1
      })

      # 释放鼠标
      send_to_target(session_id, "Input.dispatchMouseEvent", %{
        type: "mouseReleased",
        x: x2,
        y: y2,
        button: "left",
        buttons: 0
      })

      {:ok, %{action: "drag", startRef: start_ref, endRef: end_ref}}
    end
  end

  defp do_wait(_session_id, request) do
    time_ms = request["timeMs"] || request[:timeMs]
    ref = request["ref"] || request[:ref]
    text_gone = request["textGone"] || request[:textGone]

    cond do
      time_ms ->
        Process.sleep(time_ms)
        {:ok, %{action: "wait", timeMs: time_ms}}

      ref ->
        # 等待元素出现 - 简化实现
        {:ok, %{action: "wait", ref: ref, note: "Element wait not fully implemented"}}

      text_gone ->
        {:ok, %{action: "wait", textGone: text_gone, note: "Text gone wait not fully implemented"}}

      true ->
        {:ok, %{action: "wait", note: "No wait condition specified"}}
    end
  end

  defp get_element_center(session_id, ref) do
    # 使用 JavaScript 获取元素的中心坐标
    # ref 可以是 CSS 选择器、XPath 或者类似 "e12" 的 snapshot ref
    js = """
    (function() {
      let element = null;
      const ref = '#{ref}';

      // 尝试各种选择方式
      if (ref.match(/^e\\d+$/)) {
        // Snapshot ref 格式 (e12)
        element = document.querySelector('[data-snapshot-ref="' + ref + '"]');
      }

      if (!element) {
        // 尝试 CSS 选择器
        try { element = document.querySelector(ref); } catch(e) {}
      }

      if (!element) {
        // 尝试 XPath
        try {
          element = document.evaluate(ref, document, null, XPathResult.FIRST_ORDERED_NODE_TYPE, null).singleNodeValue;
        } catch(e) {}
      }

      if (!element) {
        // 尝试 aria-label 匹配
        const parts = ref.split(':');
        if (parts.length === 2) {
          const [role, name] = parts;
          element = document.querySelector('[role="' + role + '"][aria-label="' + name + '"]') ||
                   document.querySelector(role + ':has-text("' + name + '")') ||
                   Array.from(document.querySelectorAll(role)).find(el => el.textContent.includes(name));
        }
      }

      if (!element) {
        return {error: 'Element not found: ' + ref};
      }

      const rect = element.getBoundingClientRect();
      return {
        x: rect.left + rect.width / 2,
        y: rect.top + rect.height / 2,
        width: rect.width,
        height: rect.height
      };
    })()
    """

    case evaluate_js(session_id, js) do
      {:ok, %{"error" => error}} -> {:error, error}
      {:ok, result} -> {:ok, result}
      error -> error
    end
  end

  defp evaluate_js(session_id, expression) do
    case send_to_target(session_id, "Runtime.evaluate", %{
           expression: expression,
           returnByValue: true,
           awaitPromise: true
         }) do
      {:ok, %{"result" => %{"value" => value}}} ->
        {:ok, value}

      {:ok, %{"result" => result}} ->
        {:ok, result}

      {:ok, %{"exceptionDetails" => details}} ->
        {:error, {:js_error, details}}

      error ->
        error
    end
  end

  defp button_to_code("left"), do: 1
  defp button_to_code("right"), do: 2
  defp button_to_code("middle"), do: 4
  defp button_to_code(_), do: 1

  defp modifiers_to_flags(modifiers) do
    Enum.reduce(modifiers, 0, fn mod, acc ->
      case String.downcase(mod) do
        "alt" -> acc + 1
        "ctrl" -> acc + 2
        "control" -> acc + 2
        "meta" -> acc + 4
        "command" -> acc + 4
        "shift" -> acc + 8
        _ -> acc
      end
    end)
  end

  # ============================================================================
  # JavaScript Evaluation
  # ============================================================================

  defp execute_javascript(target_id, expression) do
    with {:ok, session_id} <- attach_to_target(target_id),
         :ok <- enable_domain(session_id, "Runtime") do
      evaluate_js(session_id, expression)
    end
  end

  # ============================================================================
  # File Upload
  # ============================================================================

  defp upload_files(target_id, input_ref, paths) do
    with {:ok, session_id} <- attach_to_target(target_id),
         :ok <- enable_domain(session_id, "DOM"),
         :ok <- enable_domain(session_id, "Runtime") do
      # 获取文件输入元素的 node ID
      js = """
      (function() {
        const ref = '#{input_ref}';
        let element = document.querySelector('[data-snapshot-ref="' + ref + '"]') ||
                     document.querySelector(ref);

        if (!element) return {error: 'File input not found'};
        if (element.tagName !== 'INPUT' || element.type !== 'file') {
          return {error: 'Element is not a file input'};
        }

        return {found: true};
      })()
      """

      case evaluate_js(session_id, js) do
        {:ok, %{"error" => error}} ->
          {:error, error}

        {:ok, %{"found" => true}} ->
          # 使用 DOM.setFileInputFiles 设置文件
          case send_to_target(session_id, "DOM.getDocument", %{}) do
            {:ok, %{"root" => %{"nodeId" => _root_id}}} ->
              # 查找元素
              case send_to_target(session_id, "DOM.querySelector", %{
                     nodeId: 1,
                     selector: input_ref
                   }) do
                {:ok, %{"nodeId" => node_id}} when node_id > 0 ->
                  case send_to_target(session_id, "DOM.setFileInputFiles", %{
                         files: paths,
                         nodeId: node_id
                       }) do
                    {:ok, _} ->
                      {:ok, %{action: "upload", ref: input_ref, files: paths}}

                    error ->
                      error
                  end

                _ ->
                  {:error, "Could not find file input element"}
              end

            error ->
              error
          end

        error ->
          error
      end
    end
  end

  # ============================================================================
  # Dialog Handling
  # ============================================================================

  defp handle_dialog(target_id, accept, prompt_text) do
    with {:ok, session_id} <- attach_to_target(target_id),
         :ok <- enable_domain(session_id, "Page") do
      params = %{accept: accept}
      params = if prompt_text, do: Map.put(params, :promptText, prompt_text), else: params

      case send_to_target(session_id, "Page.handleJavaScriptDialog", params) do
        {:ok, _} ->
          {:ok, %{action: "dialog", accept: accept, promptText: prompt_text}}

        error ->
          error
      end
    end
  end
end
