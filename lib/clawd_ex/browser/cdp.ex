defmodule ClawdEx.Browser.CDP do
  @moduledoc """
  Chrome DevTools Protocol 客户端

  通过 WebSocket 与 Chrome 通信，发送 CDP 命令并接收响应。
  """

  use GenServer

  require Logger

  @type state :: %{
          ws_conn: pid() | nil,
          ws_ref: reference() | nil,
          pending: map(),
          next_id: integer(),
          callbacks: map()
        }

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  启动 CDP 客户端并连接到 Chrome
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  连接到 Chrome DevTools WebSocket
  """
  @spec connect(String.t()) :: :ok | {:error, term()}
  def connect(ws_url) do
    GenServer.call(__MODULE__, {:connect, ws_url}, 30_000)
  end

  @doc """
  断开连接
  """
  @spec disconnect() :: :ok
  def disconnect do
    GenServer.call(__MODULE__, :disconnect)
  end

  @doc """
  发送 CDP 命令
  """
  @spec send_command(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def send_command(method, params \\ %{}) do
    GenServer.call(__MODULE__, {:send_command, method, params}, 30_000)
  end

  @doc """
  获取连接状态
  """
  @spec connected?() :: boolean()
  def connected? do
    GenServer.call(__MODULE__, :connected?)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    state = %{
      ws_conn: nil,
      ws_ref: nil,
      pending: %{},
      next_id: 1,
      callbacks: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:connect, ws_url}, _from, state) do
    case do_connect(ws_url) do
      {:ok, ws_conn, ws_ref} ->
        new_state = %{state | ws_conn: ws_conn, ws_ref: ws_ref}
        {:reply, :ok, new_state}

      {:error, reason} = error ->
        Logger.error("CDP connect failed: #{inspect(reason)}")
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call(:disconnect, _from, state) do
    if state.ws_conn do
      # 发送关闭帧
      :gun.close(state.ws_conn)
    end

    new_state = %{state | ws_conn: nil, ws_ref: nil, pending: %{}}
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:send_command, method, params}, from, state) do
    if state.ws_conn == nil do
      {:reply, {:error, :not_connected}, state}
    else
      id = state.next_id
      message = Jason.encode!(%{id: id, method: method, params: params})

      case :gun.ws_send(state.ws_conn, state.ws_ref, {:text, message}) do
        :ok ->
          new_pending = Map.put(state.pending, id, from)
          new_state = %{state | pending: new_pending, next_id: id + 1}
          {:noreply, new_state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  @impl true
  def handle_call(:connected?, _from, state) do
    {:reply, state.ws_conn != nil, state}
  end

  @impl true
  def handle_info({:gun_ws, _conn, _ref, {:text, data}}, state) do
    case Jason.decode(data) do
      {:ok, %{"id" => id, "result" => result}} ->
        case Map.pop(state.pending, id) do
          {nil, _pending} ->
            {:noreply, state}

          {from, new_pending} ->
            GenServer.reply(from, {:ok, result})
            {:noreply, %{state | pending: new_pending}}
        end

      {:ok, %{"id" => id, "error" => error}} ->
        case Map.pop(state.pending, id) do
          {nil, _pending} ->
            {:noreply, state}

          {from, new_pending} ->
            GenServer.reply(from, {:error, error})
            {:noreply, %{state | pending: new_pending}}
        end

      {:ok, %{"method" => _method, "params" => _params}} ->
        # Event - 暂时忽略，后续可以添加事件回调
        {:noreply, state}

      {:error, reason} ->
        Logger.warning("CDP parse error: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:gun_down, conn, _protocol, _reason, _killed}, state) do
    if conn == state.ws_conn do
      Logger.warning("CDP WebSocket disconnected")
      # 回复所有 pending 请求
      Enum.each(state.pending, fn {_id, from} ->
        GenServer.reply(from, {:error, :disconnected})
      end)

      {:noreply, %{state | ws_conn: nil, ws_ref: nil, pending: %{}}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:gun_up, _conn, _protocol}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:gun_upgrade, _conn, _ref, ["websocket"], _headers}, state) do
    Logger.debug("CDP WebSocket upgraded")
    {:noreply, state}
  end

  @impl true
  def handle_info({:gun_response, _conn, _ref, _fin, _status, _headers}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:gun_error, _conn, _ref, reason}, state) do
    Logger.error("CDP gun error: #{inspect(reason)}")
    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("CDP unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp do_connect(ws_url) do
    uri = URI.parse(ws_url)
    host = String.to_charlist(uri.host || "localhost")
    port = uri.port || 9222
    path = uri.path || "/devtools/browser"

    Logger.debug("Connecting to CDP: #{host}:#{port}#{path}")

    with {:ok, conn} <- :gun.open(host, port, %{protocols: [:http]}),
         {:ok, _protocol} <- :gun.await_up(conn, 5000) do
      ws_ref = :gun.ws_upgrade(conn, path)

      receive do
        {:gun_upgrade, ^conn, ^ws_ref, ["websocket"], _headers} ->
          {:ok, conn, ws_ref}

        {:gun_response, ^conn, ^ws_ref, _fin, status, _headers} ->
          :gun.close(conn)
          {:error, {:upgrade_failed, status}}

        {:gun_error, ^conn, ^ws_ref, reason} ->
          :gun.close(conn)
          {:error, reason}
      after
        10_000 ->
          :gun.close(conn)
          {:error, :timeout}
      end
    end
  end
end
