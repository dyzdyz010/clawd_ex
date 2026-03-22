defmodule ClawdEx.Cron.ParserTest do
  use ExUnit.Case, async: true

  alias ClawdEx.Cron.Parser

  # ===========================================================================
  # Parsing
  # ===========================================================================

  describe "parse/1" do
    test "wildcard expression (* * * * *)" do
      assert {:ok, %{minute: :any, hour: :any, day: :any, month: :any, weekday: :any}} =
               Parser.parse("* * * * *")
    end

    test "specific values" do
      assert {:ok, %{minute: {:list, [30]}, hour: {:list, [9]}, day: :any, month: :any, weekday: :any}} =
               Parser.parse("30 9 * * *")
    end

    test "step values (*/5)" do
      {:ok, cron} = Parser.parse("*/5 * * * *")
      assert {:list, minutes} = cron.minute
      assert minutes == [0, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55]
    end

    test "step values (*/15)" do
      {:ok, cron} = Parser.parse("*/15 * * * *")
      assert {:list, [0, 15, 30, 45]} = cron.minute
    end

    test "range values (1-5)" do
      {:ok, cron} = Parser.parse("* * * * 1-5")
      assert {:list, [1, 2, 3, 4, 5]} = cron.weekday
    end

    test "list values (1,15,30)" do
      {:ok, cron} = Parser.parse("1,15,30 * * * *")
      assert {:list, [1, 15, 30]} = cron.minute
    end

    test "range with step (1-10/2)" do
      {:ok, cron} = Parser.parse("1-10/2 * * * *")
      assert {:list, [1, 3, 5, 7, 9]} = cron.minute
    end

    test "complex expression" do
      {:ok, cron} = Parser.parse("0,30 9-17 * * 1-5")
      assert {:list, [0, 30]} = cron.minute
      assert {:list, [9, 10, 11, 12, 13, 14, 15, 16, 17]} = cron.hour
      assert :any = cron.day
      assert :any = cron.month
      assert {:list, [1, 2, 3, 4, 5]} = cron.weekday
    end

    test "mixed list with range (1,5-7,10)" do
      {:ok, cron} = Parser.parse("1,5-7,10 * * * *")
      assert {:list, [1, 5, 6, 7, 10]} = cron.minute
    end
  end

  # ===========================================================================
  # Shorthand Expressions
  # ===========================================================================

  describe "parse/1 shorthands" do
    test "@hourly" do
      {:ok, cron} = Parser.parse("@hourly")
      assert {:list, [0]} = cron.minute
      assert :any = cron.hour
    end

    test "@daily" do
      {:ok, cron} = Parser.parse("@daily")
      assert {:list, [0]} = cron.minute
      assert {:list, [0]} = cron.hour
      assert :any = cron.day
    end

    test "@weekly" do
      {:ok, cron} = Parser.parse("@weekly")
      assert {:list, [0]} = cron.minute
      assert {:list, [0]} = cron.hour
      assert {:list, [0]} = cron.weekday
    end

    test "@monthly" do
      {:ok, cron} = Parser.parse("@monthly")
      assert {:list, [0]} = cron.minute
      assert {:list, [0]} = cron.hour
      assert {:list, [1]} = cron.day
    end

    test "@yearly" do
      {:ok, cron} = Parser.parse("@yearly")
      assert {:list, [0]} = cron.minute
      assert {:list, [0]} = cron.hour
      assert {:list, [1]} = cron.day
      assert {:list, [1]} = cron.month
    end

    test "@annually is same as @yearly" do
      {:ok, yearly} = Parser.parse("@yearly")
      {:ok, annually} = Parser.parse("@annually")
      assert yearly == annually
    end

    test "@midnight is same as @daily" do
      {:ok, daily} = Parser.parse("@daily")
      {:ok, midnight} = Parser.parse("@midnight")
      assert daily == midnight
    end
  end

  # ===========================================================================
  # Error Cases
  # ===========================================================================

  describe "parse/1 errors" do
    test "wrong number of fields" do
      assert {:error, msg} = Parser.parse("* * *")
      assert msg =~ "expected 5 fields"
    end

    test "invalid value" do
      assert {:error, _} = Parser.parse("60 * * * *")
    end

    test "invalid range" do
      assert {:error, _} = Parser.parse("* * * * 0-7")
    end

    test "invalid step" do
      assert {:error, _} = Parser.parse("*/0 * * * *")
    end

    test "empty string" do
      assert {:error, _} = Parser.parse("")
    end
  end

  # ===========================================================================
  # parse!/1
  # ===========================================================================

  describe "parse!/1" do
    test "returns parsed cron on valid input" do
      cron = Parser.parse!("0 * * * *")
      assert {:list, [0]} = cron.minute
    end

    test "raises on invalid input" do
      assert_raise ArgumentError, fn ->
        Parser.parse!("invalid")
      end
    end
  end

  # ===========================================================================
  # Next Run Calculation
  # ===========================================================================

  describe "next_run/2" do
    test "every hour at :00" do
      {:ok, cron} = Parser.parse("0 * * * *")
      from = ~U[2026-03-22 10:30:00Z]
      next = Parser.next_run(cron, from)

      assert next.minute == 0
      assert next.hour == 11
      assert next.day == 22
    end

    test "specific time (30 9 * * *)" do
      {:ok, cron} = Parser.parse("30 9 * * *")
      from = ~U[2026-03-22 10:00:00Z]
      next = Parser.next_run(cron, from)

      # Next 9:30 is tomorrow
      assert next.minute == 30
      assert next.hour == 9
      assert next.day == 23
    end

    test "every 5 minutes" do
      {:ok, cron} = Parser.parse("*/5 * * * *")
      from = ~U[2026-03-22 10:03:00Z]
      next = Parser.next_run(cron, from)

      assert next.minute == 5
      assert next.hour == 10
    end

    test "specific day of month" do
      {:ok, cron} = Parser.parse("0 0 1 * *")
      from = ~U[2026-03-15 00:00:00Z]
      next = Parser.next_run(cron, from)

      assert next.day == 1
      assert next.month == 4
    end

    test "weekday-only schedule (Mon-Fri)" do
      {:ok, cron} = Parser.parse("0 9 * * 1-5")
      # 2026-03-22 is a Sunday
      from = ~U[2026-03-22 10:00:00Z]
      next = Parser.next_run(cron, from)

      # Next weekday is Monday March 23
      assert next.hour == 9
      assert next.minute == 0
      assert Date.day_of_week(next) in 1..5
    end

    test "next run is always in the future" do
      {:ok, cron} = Parser.parse("* * * * *")
      from = DateTime.utc_now()
      next = Parser.next_run(cron, from)

      assert DateTime.compare(next, from) == :gt
    end
  end

  # ===========================================================================
  # matches?/2
  # ===========================================================================

  describe "matches?/2" do
    test "wildcard matches everything" do
      {:ok, cron} = Parser.parse("* * * * *")
      assert Parser.matches?(cron, ~U[2026-03-22 10:30:00Z])
    end

    test "specific time matches" do
      {:ok, cron} = Parser.parse("30 10 * * *")
      assert Parser.matches?(cron, ~U[2026-03-22 10:30:00Z])
      refute Parser.matches?(cron, ~U[2026-03-22 10:31:00Z])
    end

    test "step values match" do
      {:ok, cron} = Parser.parse("*/15 * * * *")
      assert Parser.matches?(cron, ~U[2026-03-22 10:00:00Z])
      assert Parser.matches?(cron, ~U[2026-03-22 10:15:00Z])
      assert Parser.matches?(cron, ~U[2026-03-22 10:30:00Z])
      assert Parser.matches?(cron, ~U[2026-03-22 10:45:00Z])
      refute Parser.matches?(cron, ~U[2026-03-22 10:10:00Z])
    end

    test "weekday matching (Sunday = 0)" do
      {:ok, cron} = Parser.parse("* * * * 0")
      # 2026-03-22 is a Sunday
      assert Parser.matches?(cron, ~U[2026-03-22 10:00:00Z])
      # 2026-03-23 is a Monday
      refute Parser.matches?(cron, ~U[2026-03-23 10:00:00Z])
    end
  end
end
