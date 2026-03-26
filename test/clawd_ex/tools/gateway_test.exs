defmodule ClawdEx.Tools.GatewayTest do
  use ExUnit.Case, async: false

  alias ClawdEx.Tools.Gateway

  @moduletag :gateway

  describe "execute/2 - config.get" do
    test "returns full config when no key specified" do
      assert {:ok, %{config: config}} = Gateway.execute(%{"action" => "config.get"}, %{})
      assert is_map(config)
    end

    test "returns specific key with dot notation" do
      # First ensure default config exists
      Gateway.execute(%{"action" => "config.get"}, %{})

      assert {:ok, %{config: value}} =
               Gateway.execute(%{"action" => "config.get", "key" => "app.name"}, %{})

      assert is_binary(value)
    end

    test "returns error for non-existent key" do
      assert {:error, msg} =
               Gateway.execute(%{"action" => "config.get", "key" => "nonexistent.path"}, %{})

      assert String.contains?(msg, "not found")
    end
  end

  describe "execute/2 - config.schema" do
    test "returns config schema" do
      assert {:ok, %{schema: schema}} = Gateway.execute(%{"action" => "config.schema"}, %{})
      assert is_map(schema)
      assert schema["type"] == "object"
      assert is_map(schema["properties"])
    end
  end

  describe "execute/2 - config.apply" do
    test "applies new configuration" do
      new_config = %{
        "app" => %{"name" => "test_app", "version" => "1.0.0"},
        "features" => %{"discord" => false, "telegram" => true, "web_api" => true},
        "limits" => %{
          "max_sessions" => 50,
          "session_timeout_minutes" => 30,
          "max_message_length" => 2048
        },
        "logging" => %{"level" => "debug", "format" => "text"}
      }

      assert {:ok, %{status: "applied", config: ^new_config}} =
               Gateway.execute(%{"action" => "config.apply", "config" => new_config}, %{})

      # Verify it was saved
      assert {:ok, %{config: loaded}} = Gateway.execute(%{"action" => "config.get"}, %{})
      assert loaded["app"]["name"] == "test_app"
    end

    test "returns error when config is missing" do
      assert {:error, msg} = Gateway.execute(%{"action" => "config.apply"}, %{})
      assert String.contains?(msg, "required")
    end
  end

  describe "execute/2 - config.patch" do
    test "patches configuration partially" do
      # First set a known config
      initial_config = %{
        "app" => %{"name" => "patch_test", "version" => "1.0.0"},
        "features" => %{"discord" => true, "telegram" => false, "web_api" => true},
        "limits" => %{
          "max_sessions" => 100,
          "session_timeout_minutes" => 60,
          "max_message_length" => 4096
        },
        "logging" => %{"level" => "info", "format" => "json"}
      }

      Gateway.execute(%{"action" => "config.apply", "config" => initial_config}, %{})

      # Now patch just one part
      patch = %{"features" => %{"telegram" => true}}

      assert {:ok, %{status: "patched", config: result}} =
               Gateway.execute(%{"action" => "config.patch", "config" => patch}, %{})

      # Telegram should be updated
      assert result["features"]["telegram"] == true
      # Others should remain
      assert result["features"]["discord"] == true
      assert result["app"]["name"] == "patch_test"
    end

    test "returns error when config is missing" do
      assert {:error, msg} = Gateway.execute(%{"action" => "config.patch"}, %{})
      assert String.contains?(msg, "required")
    end
  end

  describe "execute/2 - restart" do
    test "schedules restart" do
      assert {:ok, %{status: "scheduled", message: msg}} =
               Gateway.execute(%{"action" => "restart"}, %{})

      assert String.contains?(msg, "restart")
    end
  end

  describe "execute/2 - status" do
    test "returns system status" do
      assert {:ok, status} = Gateway.execute(%{"action" => "status"}, %{})
      assert is_integer(status[:uptime_seconds])
      assert status[:uptime_seconds] >= 0
      assert is_binary(status[:uptime_human])
      assert is_integer(status[:sessions])
      assert is_integer(status[:agent_loops])
      assert is_map(status[:memory])
      assert is_float(status[:memory][:total_mb])
      assert is_float(status[:memory][:processes_mb])
      assert is_float(status[:memory][:ets_mb])
      assert is_binary(status[:version])
      assert is_binary(status[:otp_release])
      assert is_binary(status[:elixir_version])
    end

  end

  describe "execute/2 - log_level" do
    test "returns current level when no level param" do
      assert {:ok, %{current_level: level}} =
               Gateway.execute(%{"action" => "log_level"}, %{})

      assert level in ["debug", "info", "warning", "error", "notice"]
    end

    test "sets and restores log level" do
      original_level = Logger.level()

      assert {:ok, %{status: "updated", level: "debug"}} =
               Gateway.execute(%{"action" => "log_level", "level" => "debug"}, %{})
      assert Logger.level() == :debug

      assert {:ok, %{status: "updated", level: "warning"}} =
               Gateway.execute(%{"action" => "log_level", "level" => "warning"}, %{})
      assert Logger.level() == :warning

      Logger.configure(level: original_level)
    end

    test "returns error for invalid level" do
      assert {:error, msg} =
               Gateway.execute(%{"action" => "log_level", "level" => "trace"}, %{})

      assert String.contains?(msg, "Invalid log level")
    end
  end

  describe "execute/2 - config.patch auto-applies log level" do
    test "auto-applies log level when logging.level is patched" do
      original_level = Logger.level()

      # Set a known config first
      initial_config = %{
        "app" => %{"name" => "log_test", "version" => "1.0.0"},
        "features" => %{"discord" => true, "telegram" => false, "web_api" => true},
        "limits" => %{
          "max_sessions" => 100,
          "session_timeout_minutes" => 60,
          "max_message_length" => 4096
        },
        "logging" => %{"level" => "info", "format" => "json"}
      }

      Gateway.execute(%{"action" => "config.apply", "config" => initial_config}, %{})

      # Patch logging level
      patch = %{"logging" => %{"level" => "debug"}}

      assert {:ok, %{status: "patched"}} =
               Gateway.execute(%{"action" => "config.patch", "config" => patch}, %{})

      assert Logger.level() == :debug

      # Restore
      Logger.configure(level: original_level)
    end
  end

  describe "execute/2 - unknown action" do
    test "returns error for unknown action" do
      assert {:error, msg} = Gateway.execute(%{"action" => "unknown"}, %{})
      assert String.contains?(msg, "Unknown action")
    end
  end
end
