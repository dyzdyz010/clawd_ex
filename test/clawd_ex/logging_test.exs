defmodule ClawdEx.LoggingTest do
  use ExUnit.Case, async: true

  alias ClawdEx.Logging

  describe "set_level/1" do
    test "accepts valid levels" do
      original = Logging.get_level()

      try do
        assert :ok = Logging.set_level(:debug)
        assert :debug = Logging.get_level()

        assert :ok = Logging.set_level(:info)
        assert :info = Logging.get_level()

        assert :ok = Logging.set_level(:warning)
        assert :warning = Logging.get_level()

        assert :ok = Logging.set_level(:error)
        assert :error = Logging.get_level()
      after
        Logging.set_level(original)
      end
    end

    test "rejects invalid levels" do
      assert {:error, :invalid_level} = Logging.set_level(:nope)
      assert {:error, :invalid_level} = Logging.set_level(:trace)
      assert {:error, :invalid_level} = Logging.set_level("info")
    end
  end

  describe "valid_levels/0" do
    test "returns the four standard levels" do
      assert Logging.valid_levels() == [:debug, :info, :warning, :error]
    end
  end

  describe "log_dir/0" do
    test "returns a string path" do
      dir = Logging.log_dir()
      assert is_binary(dir)
      assert String.length(dir) > 0
    end
  end
end
