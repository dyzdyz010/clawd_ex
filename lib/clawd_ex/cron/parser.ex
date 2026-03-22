defmodule ClawdEx.Cron.Parser do
  @moduledoc """
  Cron expression parser.

  Supports standard 5-field format: minute hour day month weekday
  Also supports shorthand expressions: @hourly, @daily, @weekly, @monthly, @yearly, @annually

  Special characters:
  - `*` — any value
  - `*/n` — every n units
  - `n-m` — range from n to m
  - `n,m,o` — list of specific values
  - `n-m/s` — range with step
  """

  @type parsed_cron :: %{
          minute: field(),
          hour: field(),
          day: field(),
          month: field(),
          weekday: field()
        }

  @type field :: :any | {:value, integer()} | {:list, [integer()]}

  @shorthands %{
    "@yearly" => "0 0 1 1 *",
    "@annually" => "0 0 1 1 *",
    "@monthly" => "0 0 1 * *",
    "@weekly" => "0 0 * * 0",
    "@daily" => "0 0 * * *",
    "@midnight" => "0 0 * * *",
    "@hourly" => "0 * * * *"
  }

  @field_ranges %{
    minute: {0, 59},
    hour: {0, 23},
    day: {1, 31},
    month: {1, 12},
    weekday: {0, 6}
  }

  @doc """
  Parse a cron expression string into a structured representation.

  ## Examples

      iex> ClawdEx.Cron.Parser.parse("*/5 * * * *")
      {:ok, %{minute: {:list, [0, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55]}, hour: :any, day: :any, month: :any, weekday: :any}}

      iex> ClawdEx.Cron.Parser.parse("@hourly")
      {:ok, %{minute: {:list, [0]}, hour: :any, day: :any, month: :any, weekday: :any}}
  """
  @spec parse(String.t()) :: {:ok, parsed_cron()} | {:error, String.t()}
  def parse(expression) do
    expression = String.trim(expression)

    # Check for shorthand
    expression =
      case Map.get(@shorthands, String.downcase(expression)) do
        nil -> expression
        expanded -> expanded
      end

    parts = String.split(expression, ~r/\s+/, trim: true)

    if length(parts) != 5 do
      {:error, "expected 5 fields (minute hour day month weekday), got #{length(parts)}"}
    else
      [minute, hour, day, month, weekday] = parts

      with {:ok, min} <- parse_field(minute, :minute),
           {:ok, hr} <- parse_field(hour, :hour),
           {:ok, d} <- parse_field(day, :day),
           {:ok, mon} <- parse_field(month, :month),
           {:ok, wd} <- parse_field(weekday, :weekday) do
        {:ok, %{minute: min, hour: hr, day: d, month: mon, weekday: wd}}
      end
    end
  end

  @doc """
  Parse a cron expression, raising on error.
  """
  @spec parse!(String.t()) :: parsed_cron()
  def parse!(expression) do
    case parse(expression) do
      {:ok, cron} -> cron
      {:error, reason} -> raise ArgumentError, "Invalid cron expression: #{reason}"
    end
  end

  @doc """
  Calculate the next run time after `from` that matches the cron expression.

  ## Examples

      iex> {:ok, cron} = ClawdEx.Cron.Parser.parse("0 * * * *")
      iex> from = ~U[2026-03-22 10:30:00Z]
      iex> ClawdEx.Cron.Parser.next_run(cron, from)
      ~U[2026-03-22 11:00:00Z]
  """
  @spec next_run(parsed_cron(), DateTime.t()) :: DateTime.t()
  def next_run(cron, from \\ DateTime.utc_now()) do
    # Start from the next minute boundary
    candidate =
      from
      |> DateTime.add(60, :second)
      |> Map.put(:second, 0)
      |> Map.put(:microsecond, {0, 6})

    find_next(cron, candidate)
  end

  @doc """
  Check if a given DateTime matches the cron expression.
  """
  @spec matches?(parsed_cron(), DateTime.t()) :: boolean()
  def matches?(cron, datetime) do
    matches_field?(cron.minute, datetime.minute) and
      matches_field?(cron.hour, datetime.hour) and
      matches_field?(cron.day, datetime.day) and
      matches_field?(cron.month, datetime.month) and
      matches_field?(cron.weekday, day_of_week_sunday_zero(datetime))
  end

  # ---------------------------------------------------------------------------
  # Field Parsing
  # ---------------------------------------------------------------------------

  defp parse_field("*", _field_name), do: {:ok, :any}

  defp parse_field(expr, field_name) do
    {min, max} = Map.fetch!(@field_ranges, field_name)

    # Handle comma-separated list (can contain ranges and steps)
    parts = String.split(expr, ",")

    values =
      Enum.reduce_while(parts, {:ok, []}, fn part, {:ok, acc} ->
        case parse_single(part, min, max, field_name) do
          {:ok, vals} -> {:cont, {:ok, acc ++ vals}}
          {:error, _} = err -> {:halt, err}
        end
      end)

    case values do
      {:ok, vals} ->
        vals = vals |> Enum.sort() |> Enum.uniq()
        {:ok, {:list, vals}}

      {:error, _} = err ->
        err
    end
  end

  # Parse a single part (could be *, */n, n, n-m, n-m/s)
  defp parse_single("*/" <> step_str, min, max, field_name) do
    case Integer.parse(step_str) do
      {step, ""} when step > 0 ->
        vals = for v <- min..max, rem(v - min, step) == 0, do: v
        {:ok, vals}

      _ ->
        {:error, "invalid step in #{field_name}: */#{step_str}"}
    end
  end

  defp parse_single(part, min, max, field_name) do
    cond do
      String.contains?(part, "/") ->
        # range/step: n-m/s or n/s
        parse_range_step(part, min, max, field_name)

      String.contains?(part, "-") ->
        # range: n-m
        parse_range(part, min, max, field_name)

      true ->
        # single value
        case Integer.parse(part) do
          {v, ""} when v >= min and v <= max ->
            {:ok, [v]}

          {_, ""} ->
            {:error, "value out of range in #{field_name}: #{part} (#{min}-#{max})"}

          _ ->
            {:error, "invalid value in #{field_name}: #{part}"}
        end
    end
  end

  defp parse_range(part, min, max, field_name) do
    case String.split(part, "-") do
      [start_s, end_s] ->
        with {start_i, ""} <- Integer.parse(start_s),
             {end_i, ""} <- Integer.parse(end_s) do
          cond do
            start_i < min or start_i > max ->
              {:error, "range start out of bounds in #{field_name}: #{part}"}

            end_i < min or end_i > max ->
              {:error, "range end out of bounds in #{field_name}: #{part}"}

            start_i > end_i ->
              {:error, "invalid range in #{field_name}: #{part} (start > end)"}

            true ->
              {:ok, Enum.to_list(start_i..end_i)}
          end
        else
          _ -> {:error, "invalid range in #{field_name}: #{part}"}
        end

      _ ->
        {:error, "invalid range format in #{field_name}: #{part}"}
    end
  end

  defp parse_range_step(part, min, max, field_name) do
    case String.split(part, "/") do
      [range_part, step_str] ->
        case Integer.parse(step_str) do
          {step, ""} when step > 0 ->
            # Determine the range
            {range_start, range_end} =
              case range_part do
                "*" ->
                  {min, max}

                _ ->
                  case parse_range(range_part, min, max, field_name) do
                    {:ok, vals} -> {List.first(vals), List.last(vals)}
                    _ -> {nil, nil}
                  end
              end

            if range_start && range_end do
              vals = for v <- range_start..range_end, rem(v - range_start, step) == 0, do: v
              {:ok, vals}
            else
              {:error, "invalid range/step in #{field_name}: #{part}"}
            end

          _ ->
            {:error, "invalid step in #{field_name}: #{part}"}
        end

      _ ->
        {:error, "invalid range/step format in #{field_name}: #{part}"}
    end
  end

  # ---------------------------------------------------------------------------
  # Next Run Calculation
  # ---------------------------------------------------------------------------

  # Efficient next-run finder. Instead of iterating minute-by-minute,
  # we try to jump to the next matching value for each field.
  defp find_next(cron, candidate) do
    # Safety: don't search more than ~2 years ahead
    max_date = DateTime.add(candidate, 366 * 2 * 24 * 3600, :second)

    do_find_next(cron, candidate, max_date)
  end

  defp do_find_next(cron, candidate, max_date) do
    if DateTime.compare(candidate, max_date) == :gt do
      # Give up, return max_date
      max_date
    else
      cond do
        # Check month
        not matches_field?(cron.month, candidate.month) ->
          # Jump to next matching month
          case next_matching_value(cron.month, candidate.month, 1, 12) do
            {:same, _} ->
              # Shouldn't happen since we already know it doesn't match
              do_find_next(cron, advance_month(candidate), max_date)

            {:next, month} ->
              new_candidate = set_month(candidate, month)
              do_find_next(cron, new_candidate, max_date)

            :wrap ->
              # Wrap to next year
              new_candidate =
                candidate
                |> Map.put(:year, candidate.year + 1)
                |> set_month(first_matching_value(cron.month, 1))

              do_find_next(cron, new_candidate, max_date)
          end

        # Check day of month and weekday
        not (matches_field?(cron.day, candidate.day) and
               matches_field?(cron.weekday, day_of_week_sunday_zero(candidate))) ->
          do_find_next(cron, advance_day(candidate), max_date)

        # Check hour
        not matches_field?(cron.hour, candidate.hour) ->
          case next_matching_value(cron.hour, candidate.hour, 0, 23) do
            {:same, _} ->
              do_find_next(cron, advance_hour(candidate), max_date)

            {:next, hour} ->
              new_candidate = set_hour(candidate, hour)
              do_find_next(cron, new_candidate, max_date)

            :wrap ->
              new_candidate = advance_day(candidate)
              do_find_next(cron, new_candidate, max_date)
          end

        # Check minute
        not matches_field?(cron.minute, candidate.minute) ->
          case next_matching_value(cron.minute, candidate.minute, 0, 59) do
            {:same, _} ->
              do_find_next(cron, advance_minute(candidate), max_date)

            {:next, minute} ->
              new_candidate = Map.put(candidate, :minute, minute)
              do_find_next(cron, new_candidate, max_date)

            :wrap ->
              new_candidate = advance_hour(candidate)
              do_find_next(cron, new_candidate, max_date)
          end

        # All fields match!
        true ->
          candidate
      end
    end
  end

  # Find the next value >= current in the field's value set
  defp next_matching_value(:any, current, _min, _max), do: {:same, current}

  defp next_matching_value({:list, values}, current, _min, _max) do
    case Enum.find(values, &(&1 >= current)) do
      nil -> :wrap
      ^current -> {:same, current}
      v -> {:next, v}
    end
  end

  defp first_matching_value(:any, min), do: min
  defp first_matching_value({:list, [first | _]}, _min), do: first

  # ---------------------------------------------------------------------------
  # Field Matching
  # ---------------------------------------------------------------------------

  defp matches_field?(:any, _value), do: true
  defp matches_field?({:list, values}, value), do: value in values

  # ---------------------------------------------------------------------------
  # Date/Time Manipulation Helpers
  # ---------------------------------------------------------------------------

  # Convert Elixir's Monday=1..Sunday=7 to Sunday=0..Saturday=6
  defp day_of_week_sunday_zero(datetime) do
    case Date.day_of_week(datetime) do
      7 -> 0
      n -> n
    end
  end

  defp advance_minute(dt) do
    DateTime.add(dt, 60, :second)
    |> Map.put(:second, 0)
    |> Map.put(:microsecond, {0, 6})
  end

  defp advance_hour(dt) do
    dt
    |> Map.put(:minute, 0)
    |> Map.put(:second, 0)
    |> Map.put(:microsecond, {0, 6})
    |> DateTime.add(3600, :second)
  end

  defp advance_day(dt) do
    dt
    |> Map.put(:hour, 0)
    |> Map.put(:minute, 0)
    |> Map.put(:second, 0)
    |> Map.put(:microsecond, {0, 6})
    |> DateTime.add(86400, :second)
  end

  defp advance_month(dt) do
    set_month(dt, dt.month + 1)
  end

  defp set_month(dt, month) when month > 12 do
    dt
    |> Map.put(:year, dt.year + 1)
    |> set_month(month - 12)
  end

  defp set_month(dt, month) do
    # Clamp day to max days in the target month
    max_day = Calendar.ISO.days_in_month(dt.year, month)
    day = min(dt.day, max_day)

    case DateTime.new(Date.new!(dt.year, month, day), Time.new!(0, 0, 0, {0, 6})) do
      {:ok, new_dt} ->
        %{new_dt | time_zone: dt.time_zone, zone_abbr: dt.zone_abbr,
          utc_offset: dt.utc_offset, std_offset: dt.std_offset}

      _ ->
        # Fallback: just set fields directly
        %{dt | month: month, day: 1, hour: 0, minute: 0, second: 0, microsecond: {0, 6}}
    end
  end

  defp set_hour(dt, hour) do
    %{dt | hour: hour, minute: 0, second: 0, microsecond: {0, 6}}
  end
end
