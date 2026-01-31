defmodule ClawdEx.Nodes.Node do
  @moduledoc """
  节点结构定义

  表示一个远程配对的节点设备，可以是手机、桌面电脑等。
  """

  @type status :: :pending | :connected | :disconnected | :rejected

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          type: String.t(),
          status: status(),
          capabilities: [String.t()],
          metadata: map(),
          connected_at: DateTime.t() | nil,
          last_seen_at: DateTime.t() | nil,
          paired_at: DateTime.t() | nil
        }

  @derive Jason.Encoder
  defstruct [
    :id,
    :name,
    :type,
    :status,
    :capabilities,
    :metadata,
    :connected_at,
    :last_seen_at,
    :paired_at
  ]

  @doc """
  创建新节点
  """
  @spec new(map()) :: t()
  def new(attrs \\ %{}) do
    now = DateTime.utc_now()

    %__MODULE__{
      id: attrs[:id] || generate_id(),
      name: attrs[:name] || "Unknown Node",
      type: attrs[:type] || "unknown",
      status: attrs[:status] || :pending,
      capabilities: attrs[:capabilities] || [],
      metadata: attrs[:metadata] || %{},
      connected_at: attrs[:connected_at],
      last_seen_at: attrs[:last_seen_at] || now,
      paired_at: attrs[:paired_at]
    }
  end

  @doc """
  更新节点状态
  """
  @spec update_status(t(), status()) :: t()
  def update_status(node, status) do
    now = DateTime.utc_now()

    case status do
      :connected ->
        %{node | status: status, connected_at: now, last_seen_at: now}

      :disconnected ->
        %{node | status: status, last_seen_at: now}

      _ ->
        %{node | status: status, last_seen_at: now}
    end
  end

  @doc """
  标记节点为已配对
  """
  @spec mark_paired(t()) :: t()
  def mark_paired(node) do
    now = DateTime.utc_now()
    %{node | status: :connected, paired_at: now, connected_at: now, last_seen_at: now}
  end

  @doc """
  更新最后活跃时间
  """
  @spec touch(t()) :: t()
  def touch(node) do
    %{node | last_seen_at: DateTime.utc_now()}
  end

  @doc """
  检查节点是否支持某项能力
  """
  @spec has_capability?(t(), String.t()) :: boolean()
  def has_capability?(node, capability) do
    capability in (node.capabilities || [])
  end

  @doc """
  将节点转换为描述 map
  """
  @spec describe(t()) :: map()
  def describe(node) do
    %{
      id: node.id,
      name: node.name,
      type: node.type,
      status: node.status,
      capabilities: node.capabilities,
      metadata: node.metadata,
      connected_at: format_datetime(node.connected_at),
      last_seen_at: format_datetime(node.last_seen_at),
      paired_at: format_datetime(node.paired_at)
    }
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp generate_id do
    :crypto.strong_rand_bytes(12)
    |> Base.encode16(case: :lower)
  end

  defp format_datetime(nil), do: nil

  defp format_datetime(dt) do
    DateTime.to_iso8601(dt)
  end
end
