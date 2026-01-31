defmodule ClawdEx.Automation.CronJobRun do
  @moduledoc """
  定时任务运行记录
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "cron_job_runs" do
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    field :status, :string  # "running", "completed", "failed", "timeout"
    field :exit_code, :integer
    field :output, :string
    field :error, :string
    field :duration_ms, :integer

    belongs_to :job, ClawdEx.Automation.CronJob

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(run, attrs) do
    run
    |> cast(attrs, [:job_id, :started_at, :finished_at, :status, :exit_code, :output, :error, :duration_ms])
    |> validate_required([:job_id, :started_at, :status])
    |> validate_inclusion(:status, ["running", "completed", "failed", "timeout"])
  end
end
