defmodule ClawdEx.A2A.Message do
  @moduledoc """
  A2A (Agent-to-Agent) 消息 Schema。

  消息类型:
  - request: 请求另一个 Agent 做某事（期待响应）
  - response: 对 request 的响应
  - notification: 单向通知（fire-and-forget）
  - delegation: 任务委托通知

  状态流转:
  - pending → delivered → processed
  - pending → expired (TTL 超时)
  - pending → failed (投递失败)
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @types ~w(request response notification delegation)
  @statuses ~w(pending delivered processed failed expired)

  schema "a2a_messages" do
    field :message_id, :string
    field :type, :string
    field :content, :string
    field :metadata, :map, default: %{}
    field :reply_to, :string
    field :status, :string, default: "pending"
    field :priority, :integer, default: 5
    field :ttl_seconds, :integer, default: 300
    field :processed_at, :utc_datetime

    belongs_to :from_agent, ClawdEx.Agents.Agent
    belongs_to :to_agent, ClawdEx.Agents.Agent

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(message_id type content)a
  @optional_fields ~w(from_agent_id to_agent_id metadata reply_to status priority ttl_seconds processed_at)a

  def changeset(message, attrs) do
    message
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:type, @types)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:priority, greater_than_or_equal_to: 1, less_than_or_equal_to: 10)
    |> unique_constraint(:message_id)
    |> foreign_key_constraint(:from_agent_id)
    |> foreign_key_constraint(:to_agent_id)
  end

  @doc "All valid message types"
  def types, do: @types

  @doc "All valid statuses"
  def statuses, do: @statuses

  @doc "Generate a unique message ID"
  def generate_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end
