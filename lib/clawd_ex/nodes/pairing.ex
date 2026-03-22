defmodule ClawdEx.Nodes.Pairing do
  @moduledoc """
  设备配对逻辑 GenServer

  管理配对码的生成、验证、审批流程。

  配对流程:
  1. generate_pair_code/0 — 生成 6 位配对码（有效期 5 分钟）
  2. verify_pair_code/2 — 设备提交配对码 + 设备信息，返回 pair_token
  3. approve_node/1 — 管理员确认，生成永久 node_token
  4. reject_node/1 — 管理员拒绝
  """

  use GenServer

  require Logger

  alias ClawdEx.Nodes.{Node, Registry}

  @pair_code_ttl_ms 5 * 60 * 1000
  @cleanup_interval_ms 60 * 1000
  @token_bytes 32

  @type pair_code_entry :: %{
          code: String.t(),
          expires_at: integer(),
          used: boolean()
        }

  @type state :: %{
          pair_codes: %{String.t() => pair_code_entry()},
          pair_tokens: %{String.t() => String.t()}
        }

  # ============================================================================
  # Public API
  # ============================================================================

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  生成 6 位配对码，有效期 5 分钟。
  返回 %{code: "123456", expires_at: DateTime}
  """
  @spec generate_pair_code() :: {:ok, map()}
  def generate_pair_code do
    GenServer.call(__MODULE__, :generate_pair_code)
  end

  @doc """
  验证配对码并注册设备为 pending。
  设备提交配对码和设备信息，返回 pair_token。

  device_info: %{name: "My iPhone", type: "mobile", capabilities: [...]}
  """
  @spec verify_pair_code(String.t(), map()) :: {:ok, map()} | {:error, atom()}
  def verify_pair_code(code, device_info) do
    GenServer.call(__MODULE__, {:verify_pair_code, code, device_info})
  end

  @doc """
  管理员确认配对，生成永久 node_token。
  """
  @spec approve_node(String.t()) :: {:ok, map()} | {:error, atom()}
  def approve_node(node_id) do
    GenServer.call(__MODULE__, {:approve_node, node_id})
  end

  @doc """
  管理员拒绝配对。
  """
  @spec reject_node(String.t()) :: :ok | {:error, atom()}
  def reject_node(node_id) do
    GenServer.call(__MODULE__, {:reject_node, node_id})
  end

  @doc """
  列出所有待确认的配对请求。
  """
  @spec list_pending() :: [Node.t()]
  def list_pending do
    Registry.list_pending()
  end

  @doc """
  撤销已配对设备。
  """
  @spec revoke_node(String.t()) :: :ok | {:error, atom()}
  def revoke_node(node_id) do
    GenServer.call(__MODULE__, {:revoke_node, node_id})
  end

  @doc """
  验证 node_token，返回对应的 node_id。
  """
  @spec verify_node_token(String.t()) :: {:ok, String.t()} | {:error, :invalid_token}
  def verify_node_token(token) do
    GenServer.call(__MODULE__, {:verify_node_token, token})
  end

  @doc """
  验证 pair_token，返回对应的 node_id。
  """
  @spec verify_pair_token(String.t()) :: {:ok, String.t()} | {:error, :invalid_token}
  def verify_pair_token(token) do
    GenServer.call(__MODULE__, {:verify_pair_token, token})
  end

  @doc """
  重置配对状态（仅用于测试）
  """
  @spec reset() :: :ok
  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    schedule_cleanup()

    state = %{
      pair_codes: %{},
      # pair_token => node_id
      pair_tokens: %{},
      # node_token => node_id
      node_tokens: %{}
    }

    Logger.info("Node Pairing service started")
    {:ok, state}
  end

  @impl true
  def handle_call(:generate_pair_code, _from, state) do
    code = generate_code()
    now = System.monotonic_time(:millisecond)

    entry = %{
      code: code,
      expires_at: now + @pair_code_ttl_ms,
      used: false
    }

    expires_at_dt =
      DateTime.utc_now()
      |> DateTime.add(@pair_code_ttl_ms, :millisecond)

    new_state = %{state | pair_codes: Map.put(state.pair_codes, code, entry)}

    result = %{
      code: code,
      expires_at: DateTime.to_iso8601(expires_at_dt),
      ttl_seconds: div(@pair_code_ttl_ms, 1000)
    }

    Logger.info("Pair code generated: #{code}")
    {:reply, {:ok, result}, new_state}
  end

  @impl true
  def handle_call({:verify_pair_code, code, device_info}, _from, state) do
    now = System.monotonic_time(:millisecond)

    case Map.get(state.pair_codes, code) do
      nil ->
        {:reply, {:error, :invalid_code}, state}

      %{used: true} ->
        {:reply, {:error, :code_already_used}, state}

      %{expires_at: expires_at} when now > expires_at ->
        # 过期，清理
        new_codes = Map.delete(state.pair_codes, code)
        {:reply, {:error, :code_expired}, %{state | pair_codes: new_codes}}

      _entry ->
        # 配对码有效，标记已使用
        pair_token = generate_token()

        # 注册为 pending 节点
        {:ok, node} =
          Registry.register_pending(%{
            name: device_info[:name] || device_info["name"] || "Unknown Device",
            type: device_info[:type] || device_info["type"] || "unknown",
            capabilities: device_info[:capabilities] || device_info["capabilities"] || [],
            metadata: device_info[:metadata] || device_info["metadata"] || %{}
          })

        # 更新 node 的 pair_token（通过 Registry）
        # 我们在 Pairing GenServer 中维护 pair_token -> node_id 映射
        updated_codes =
          Map.update!(state.pair_codes, code, fn entry -> %{entry | used: true} end)

        new_pair_tokens = Map.put(state.pair_tokens, pair_token, node.id)

        new_state = %{state | pair_codes: updated_codes, pair_tokens: new_pair_tokens}

        result = %{
          pair_token: pair_token,
          node_id: node.id,
          status: :pending
        }

        Logger.info("Pair code verified for node #{node.id} (#{node.name})")
        {:reply, {:ok, result}, new_state}
    end
  end

  @impl true
  def handle_call({:approve_node, node_id}, _from, state) do
    case Registry.approve(node_id) do
      {:ok, node} ->
        node_token = generate_token()
        new_node_tokens = Map.put(state.node_tokens, node_token, node_id)

        # 清理 pair_token
        new_pair_tokens =
          state.pair_tokens
          |> Enum.reject(fn {_token, id} -> id == node_id end)
          |> Map.new()

        new_state = %{state | node_tokens: new_node_tokens, pair_tokens: new_pair_tokens}

        result = %{
          node_id: node.id,
          node_token: node_token,
          name: node.name,
          status: :connected
        }

        Logger.info("Node approved: #{node_id}, node_token issued")

        # 广播配对成功事件
        Phoenix.PubSub.broadcast(
          ClawdEx.PubSub,
          "nodes:events",
          {:node_approved, node_id, node_token}
        )

        {:reply, {:ok, result}, new_state}

      {:error, :not_found} ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:reject_node, node_id}, _from, state) do
    case Registry.reject(node_id) do
      :ok ->
        # 清理 pair_token
        new_pair_tokens =
          state.pair_tokens
          |> Enum.reject(fn {_token, id} -> id == node_id end)
          |> Map.new()

        new_state = %{state | pair_tokens: new_pair_tokens}
        Logger.info("Node rejected: #{node_id}")
        {:reply, :ok, new_state}

      {:error, :not_found} ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:revoke_node, node_id}, _from, state) do
    case Registry.get_node(node_id) do
      {:ok, _node} ->
        # 从 Registry 移除
        Registry.remove(node_id)

        # 清理所有关联 token
        new_node_tokens =
          state.node_tokens
          |> Enum.reject(fn {_token, id} -> id == node_id end)
          |> Map.new()

        new_pair_tokens =
          state.pair_tokens
          |> Enum.reject(fn {_token, id} -> id == node_id end)
          |> Map.new()

        new_state = %{state | node_tokens: new_node_tokens, pair_tokens: new_pair_tokens}

        Logger.info("Node revoked: #{node_id}")

        # 广播撤销事件（让 WebSocket 连接断开）
        Phoenix.PubSub.broadcast(
          ClawdEx.PubSub,
          "nodes:events",
          {:node_revoked, node_id}
        )

        {:reply, :ok, new_state}

      {:error, :not_found} ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:verify_node_token, token}, _from, state) do
    case Map.get(state.node_tokens, token) do
      nil -> {:reply, {:error, :invalid_token}, state}
      node_id -> {:reply, {:ok, node_id}, state}
    end
  end

  @impl true
  def handle_call({:verify_pair_token, token}, _from, state) do
    case Map.get(state.pair_tokens, token) do
      nil -> {:reply, {:error, :invalid_token}, state}
      node_id -> {:reply, {:ok, node_id}, state}
    end
  end

  @impl true
  def handle_call(:reset, _from, _state) do
    {:reply, :ok, %{pair_codes: %{}, pair_tokens: %{}, node_tokens: %{}}}
  end

  @impl true
  def handle_info(:cleanup_expired, state) do
    now = System.monotonic_time(:millisecond)

    new_codes =
      state.pair_codes
      |> Enum.reject(fn {_code, entry} -> now > entry.expires_at end)
      |> Map.new()

    expired_count = map_size(state.pair_codes) - map_size(new_codes)

    if expired_count > 0 do
      Logger.debug("Cleaned up #{expired_count} expired pair codes")
    end

    schedule_cleanup()
    {:noreply, %{state | pair_codes: new_codes}}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.warning("Pairing: unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp generate_code do
    # 6 位数字配对码
    :rand.uniform(999_999)
    |> Integer.to_string()
    |> String.pad_leading(6, "0")
  end

  defp generate_token do
    :crypto.strong_rand_bytes(@token_bytes)
    |> Base.url_encode64(padding: false)
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup_expired, @cleanup_interval_ms)
  end
end
