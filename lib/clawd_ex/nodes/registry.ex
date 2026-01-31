defmodule ClawdEx.Nodes.Registry do
  @moduledoc """
  节点注册表

  管理所有配对节点的 GenServer，处理节点的注册、查询和状态管理。
  """

  use GenServer

  require Logger

  alias ClawdEx.Nodes.Node

  @type state :: %{
          nodes: %{String.t() => Node.t()},
          pending: %{String.t() => Node.t()}
        }

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  启动节点注册表
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  获取所有已连接节点
  """
  @spec list_nodes() :: [Node.t()]
  def list_nodes do
    GenServer.call(__MODULE__, :list_nodes)
  end

  @doc """
  获取所有待配对节点
  """
  @spec list_pending() :: [Node.t()]
  def list_pending do
    GenServer.call(__MODULE__, :list_pending)
  end

  @doc """
  根据 ID 获取节点
  """
  @spec get_node(String.t()) :: {:ok, Node.t()} | {:error, :not_found}
  def get_node(node_id) do
    GenServer.call(__MODULE__, {:get_node, node_id})
  end

  @doc """
  注册新的待配对节点
  """
  @spec register_pending(map()) :: {:ok, Node.t()}
  def register_pending(attrs) do
    GenServer.call(__MODULE__, {:register_pending, attrs})
  end

  @doc """
  批准待配对节点
  """
  @spec approve(String.t()) :: {:ok, Node.t()} | {:error, :not_found}
  def approve(node_id) do
    GenServer.call(__MODULE__, {:approve, node_id})
  end

  @doc """
  拒绝待配对节点
  """
  @spec reject(String.t()) :: :ok | {:error, :not_found}
  def reject(node_id) do
    GenServer.call(__MODULE__, {:reject, node_id})
  end

  @doc """
  更新节点状态
  """
  @spec update_status(String.t(), Node.status()) :: {:ok, Node.t()} | {:error, :not_found}
  def update_status(node_id, status) do
    GenServer.call(__MODULE__, {:update_status, node_id, status})
  end

  @doc """
  更新节点最后活跃时间
  """
  @spec touch(String.t()) :: :ok | {:error, :not_found}
  def touch(node_id) do
    GenServer.call(__MODULE__, {:touch, node_id})
  end

  @doc """
  移除节点
  """
  @spec remove(String.t()) :: :ok
  def remove(node_id) do
    GenServer.call(__MODULE__, {:remove, node_id})
  end

  @doc """
  根据名称查找节点
  """
  @spec find_by_name(String.t()) :: {:ok, Node.t()} | {:error, :not_found}
  def find_by_name(name) do
    GenServer.call(__MODULE__, {:find_by_name, name})
  end

  @doc """
  获取节点数量统计
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc """
  重置注册表状态（仅用于测试）
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
    Logger.info("Node Registry started")

    state = %{
      nodes: %{},
      pending: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:list_nodes, _from, state) do
    nodes = Map.values(state.nodes)
    {:reply, nodes, state}
  end

  @impl true
  def handle_call(:list_pending, _from, state) do
    pending = Map.values(state.pending)
    {:reply, pending, state}
  end

  @impl true
  def handle_call({:get_node, node_id}, _from, state) do
    result =
      case Map.get(state.nodes, node_id) || Map.get(state.pending, node_id) do
        nil -> {:error, :not_found}
        node -> {:ok, node}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:register_pending, attrs}, _from, state) do
    node = Node.new(Map.put(attrs, :status, :pending))
    new_pending = Map.put(state.pending, node.id, node)

    Logger.info("New pending node registered: #{node.id} (#{node.name})")

    {:reply, {:ok, node}, %{state | pending: new_pending}}
  end

  @impl true
  def handle_call({:approve, node_id}, _from, state) do
    case Map.pop(state.pending, node_id) do
      {nil, _} ->
        {:reply, {:error, :not_found}, state}

      {node, new_pending} ->
        approved_node = Node.mark_paired(node)
        new_nodes = Map.put(state.nodes, node_id, approved_node)

        Logger.info("Node approved: #{node_id} (#{node.name})")

        {:reply, {:ok, approved_node}, %{state | nodes: new_nodes, pending: new_pending}}
    end
  end

  @impl true
  def handle_call({:reject, node_id}, _from, state) do
    case Map.pop(state.pending, node_id) do
      {nil, _} ->
        {:reply, {:error, :not_found}, state}

      {node, new_pending} ->
        Logger.info("Node rejected: #{node_id} (#{node.name})")
        {:reply, :ok, %{state | pending: new_pending}}
    end
  end

  @impl true
  def handle_call({:update_status, node_id, status}, _from, state) do
    case Map.get(state.nodes, node_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      node ->
        updated_node = Node.update_status(node, status)
        new_nodes = Map.put(state.nodes, node_id, updated_node)

        Logger.debug("Node #{node_id} status updated to: #{status}")

        {:reply, {:ok, updated_node}, %{state | nodes: new_nodes}}
    end
  end

  @impl true
  def handle_call({:touch, node_id}, _from, state) do
    case Map.get(state.nodes, node_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      node ->
        updated_node = Node.touch(node)
        new_nodes = Map.put(state.nodes, node_id, updated_node)
        {:reply, :ok, %{state | nodes: new_nodes}}
    end
  end

  @impl true
  def handle_call({:remove, node_id}, _from, state) do
    new_nodes = Map.delete(state.nodes, node_id)
    new_pending = Map.delete(state.pending, node_id)

    Logger.info("Node removed: #{node_id}")

    {:reply, :ok, %{state | nodes: new_nodes, pending: new_pending}}
  end

  @impl true
  def handle_call({:find_by_name, name}, _from, state) do
    # 在 nodes 和 pending 中搜索
    all_nodes = Map.values(state.nodes) ++ Map.values(state.pending)
    name_lower = String.downcase(name)

    result =
      Enum.find(all_nodes, fn node ->
        String.downcase(node.name) == name_lower ||
          String.contains?(String.downcase(node.name), name_lower)
      end)

    case result do
      nil -> {:reply, {:error, :not_found}, state}
      node -> {:reply, {:ok, node}, state}
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    connected_count =
      state.nodes
      |> Map.values()
      |> Enum.count(&(&1.status == :connected))

    stats = %{
      total: map_size(state.nodes),
      connected: connected_count,
      disconnected: map_size(state.nodes) - connected_count,
      pending: map_size(state.pending)
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_call(:reset, _from, _state) do
    # Reset to initial empty state (for testing)
    {:reply, :ok, %{nodes: %{}, pending: %{}}}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.warning("Unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end
end
