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

    has_many :runs, ClawdEx.Cron.JobRun, foreign_key: :job_id

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
        case parse_cron_expression(schedule) do
          {:ok, _} -> changeset
          {:error, reason} -> add_error(changeset, :schedule, "invalid cron expression: #{reason}")
        end
    end
  end

  defp compute_next_run(changeset) do
    if changeset.valid? do
      schedule = get_field(changeset, :schedule)
      timezone = get_field(changeset, :timezone) || "UTC"

      case calculate_next_run(schedule, timezone) do
        {:ok, next_run} -> put_change(changeset, :next_run_at, next_run)
        {:error, _} -> changeset
      end
    else
      changeset
    end
  end

  @doc """
  Parse a cron expression and return the parsed structure.
  Supports standard 5-field cron: minute hour day month weekday
  """
  def parse_cron_expression(expression) do
    parts = String.split(expression, ~r/\s+/, trim: true)

    if length(parts) != 5 do
      {:error, "expected 5 fields (minute hour day month weekday), got #{length(parts)}"}
    else
      [minute, hour, day, month, weekday] = parts

      with {:ok, min} <- parse_field(minute, 0..59, "minute"),
           {:ok, hr} <- parse_field(hour, 0..23, "hour"),
           {:ok, d} <- parse_field(day, 1..31, "day"),
           {:ok, mon} <- parse_field(month, 1..12, "month"),
           {:ok, wd} <- parse_field(weekday, 0..6, "weekday") do
        {:ok, %{minute: min, hour: hr, day: d, month: mon, weekday: wd}}
      end
    end
  end

  defp parse_field("*", _range, _name), do: {:ok, :any}

  defp parse_field(field, range, name) do
    cond do
      # */n - step
      String.starts_with?(field, "*/") ->
        case Integer.parse(String.slice(field, 2..-1//1)) do
          {step, ""} when step > 0 -> {:ok, {:step, step}}
          _ -> {:error, "invalid step in #{name}: #{field}"}
        end

      # n-m - range
      String.contains?(field, "-") ->
        case String.split(field, "-") do
          [start_s, end_s] ->
            with {start_i, ""} <- Integer.parse(start_s),
                 {end_i, ""} <- Integer.parse(end_s),
                 true <- start_i in range and end_i in range and start_i <= end_i do
              {:ok, {:range, start_i, end_i}}
            else
              _ -> {:error, "invalid range in #{name}: #{field}"}
            end

          _ ->
            {:error, "invalid range format in #{name}: #{field}"}
        end

      # n,m,o - list
      String.contains?(field, ",") ->
        values =
          field
          |> String.split(",")
          |> Enum.map(&Integer.parse/1)

        if Enum.all?(values, fn
             {v, ""} -> v in range
             _ -> false
           end) do
          {:ok, {:list, Enum.map(values, fn {v, ""} -> v end)}}
        else
          {:error, "invalid list in #{name}: #{field}"}
        end

      # single value
      true ->
        case Integer.parse(field) do
          {value, ""} when value in range -> {:ok, {:value, value}}
          _ -> {:error, "invalid value in #{name}: #{field}"}
        end
    end
  end

  @doc """
  Calculate the next run time for a cron expression.
  """
  def calculate_next_run(schedule, _timezone \\ "UTC") do
    case parse_cron_expression(schedule) do
      {:ok, cron} ->
        now = DateTime.utc_now()
        {:ok, find_next_run(cron, now)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp find_next_run(cron, from) do
    # Start from next minute
    candidate =
      from
      |> DateTime.add(60, :second)
      |> Map.put(:second, 0)
      |> Map.put(:microsecond, {0, 6})

    find_matching_time(cron, candidate, 0)
  end

  defp find_matching_time(_cron, _candidate, iterations) when iterations > 366 * 24 * 60 do
    # Safety limit: don't search more than a year ahead
    DateTime.utc_now() |> DateTime.add(365 * 24 * 60 * 60, :second)
  end

  defp find_matching_time(cron, candidate, iterations) do
    if matches_cron?(cron, candidate) do
      candidate
    else
      find_matching_time(cron, DateTime.add(candidate, 60, :second), iterations + 1)
    end
  end

  defp matches_cron?(cron, datetime) do
    matches_field?(cron.minute, datetime.minute) and
      matches_field?(cron.hour, datetime.hour) and
      matches_field?(cron.day, datetime.day) and
      matches_field?(cron.month, datetime.month) and
      matches_field?(cron.weekday, Date.day_of_week(datetime) |> rem(7))
  end

  defp matches_field?(:any, _value), do: true
  defp matches_field?({:value, v}, value), do: v == value
  defp matches_field?({:step, step}, value), do: rem(value, step) == 0
  defp matches_field?({:range, min, max}, value), do: value >= min and value <= max
  defp matches_field?({:list, values}, value), do: value in values
end
