defmodule ClawdEx.Cron.Job do
  @moduledoc """
  Cron Job schema.

  Represents a scheduled task that runs on a cron schedule.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "cron_jobs" do
    field :name, :string
    field :description, :string
    field :schedule, :string
    field :command, :string
    field :agent_id, :string
    field :enabled, :boolean, default: true
    field :timezone, :string, default: "UTC"
    field :last_run_at, :utc_datetime_usec
    field :next_run_at, :utc_datetime_usec
    field :run_count, :integer, default: 0
    field :metadata, :map, default: %{}

    # TODO: Add job run tracking when ClawdEx.Cron.JobRun is implemented
    # has_many :runs, ClawdEx.Cron.JobRun, foreign_key: :job_id

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields ~w(name schedule command)a
  @optional_fields ~w(description agent_id enabled timezone last_run_at next_run_at run_count metadata)a

  def changeset(job, attrs) do
    job
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_schedule()
    |> unique_constraint([:name, :agent_id])
    |> compute_next_run()
  end

  defp validate_schedule(changeset) do
    case get_change(changeset, :schedule) do
      nil ->
        changeset

      schedule ->
        case ClawdEx.Cron.Parser.parse(schedule) do
          {:ok, _} ->
            changeset

          {:error, reason} ->
            add_error(changeset, :schedule, "invalid cron expression: #{reason}")
        end
    end
  end

  defp compute_next_run(changeset) do
    if changeset.valid? do
      schedule = get_field(changeset, :schedule)
      _timezone = get_field(changeset, :timezone) || "UTC"

      case ClawdEx.Cron.Parser.parse(schedule) do
        {:ok, parsed} ->
          next_run = ClawdEx.Cron.Parser.next_run(parsed)
          put_change(changeset, :next_run_at, next_run)

        {:error, _} ->
          changeset
      end
    else
      changeset
    end
  end

  @doc """
  Parse a cron expression and return the parsed structure.
  Delegates to `ClawdEx.Cron.Parser.parse/1`.
  """
  def parse_cron_expression(expression) do
    ClawdEx.Cron.Parser.parse(expression)
  end

  @doc """
  Calculate the next run time for a cron expression.
  Delegates to `ClawdEx.Cron.Parser`.
  """
  def calculate_next_run(schedule, _timezone \\ "UTC") do
    case ClawdEx.Cron.Parser.parse(schedule) do
      {:ok, parsed} ->
        {:ok, ClawdEx.Cron.Parser.next_run(parsed)}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
