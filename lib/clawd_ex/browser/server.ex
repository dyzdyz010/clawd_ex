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
end
