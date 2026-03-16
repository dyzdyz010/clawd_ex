defmodule ClawdEx.Tasks.Task do
  @moduledoc """
  Task Schema - 持久化任务，支持生命周期管理和重试。

  状态流转:
    pending → assigned → running → completed | failed | cancelled
                                → paused → running (resume)
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @statuses ~w(pending assigned running paused completed failed cancelled)

  schema "tasks" do
    field :title, :string
    field :description, :string
    field :status, :string, default: "pending"
    field :priority, :integer, default: 5
    field :session_key, :string
    field :context, :map, default: %{}
    field :result, :map, default: %{}
    field :max_retries, :integer, default: 3
    field :retry_count, :integer, default: 0
    field :timeout_seconds, :integer, default: 600
    field :scheduled_at, :utc_datetime
    field :started_at, :utc_datetime
    field :completed_at, :utc_datetime
    field :last_heartbeat_at, :utc_datetime

    belongs_to :agent, ClawdEx.Agents.Agent
    belongs_to :parent_task, __MODULE__
    has_many :subtasks, __MODULE__, foreign_key: :parent_task_id

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(title)a
  @optional_fields ~w(description status priority agent_id session_key parent_task_id
                       context result max_retries retry_count timeout_seconds
                       scheduled_at started_at completed_at last_heartbeat_at)a

  def changeset(task, attrs) do
    task
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:priority, greater_than_or_equal_to: 1, less_than_or_equal_to: 10)
    |> foreign_key_constraint(:agent_id)
    |> foreign_key_constraint(:parent_task_id)
  end

  @doc "All valid status values"
  def statuses, do: @statuses
end
