defmodule ClawdEx.Tools.GatewayTest do
  use ExUnit.Case, async: false

  alias ClawdEx.Tools.Gateway

  @moduletag :gateway

  describe "name/0" do
    test "returns gateway" do
      assert Gateway.name() == "gateway"
    end
  end

  describe "description/0" do
    test "returns description string" do
      desc = Gateway.description()
      assert is_binary(desc)
      assert String.contains?(desc, "gateway")
    end
  end

  describe "parameters/0" do
    test "returns valid parameter schema" do
      params = Gateway.parameters()
      assert params[:type] == "object"
      assert is_map(params[:properties])
      assert params[:properties][:action]
    end
  end

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

  describe "execute/2 - unknown action" do
    test "returns error for unknown action" do
      assert {:error, msg} = Gateway.execute(%{"action" => "unknown"}, %{})
      assert String.contains?(msg, "Unknown action")
    end
  end
end
