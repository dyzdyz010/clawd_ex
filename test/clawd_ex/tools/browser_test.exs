defmodule ClawdEx.Tools.BrowserTest do
  use ExUnit.Case, async: false

  alias ClawdEx.Tools.Browser

  describe "name/0" do
    test "returns 'browser'" do
      assert Browser.name() == "browser"
    end
  end

  describe "description/0" do
    test "returns a non-empty description" do
      desc = Browser.description()
      assert is_binary(desc)
      assert String.length(desc) > 0
    end
  end

  describe "parameters/0" do
    test "returns valid parameter schema" do
      params = Browser.parameters()

      assert params.type == "object"
      assert is_map(params.properties)
      assert "action" in params.required

      # Check action property
      assert params.properties.action.type == "string"
      assert is_list(params.properties.action.enum)
      assert "status" in params.properties.action.enum
      assert "start" in params.properties.action.enum
      assert "stop" in params.properties.action.enum
      assert "tabs" in params.properties.action.enum
      assert "open" in params.properties.action.enum
      assert "close" in params.properties.action.enum
    end
  end

  describe "execute/2 - status action" do
    test "returns browser status" do
      {:ok, result} = Browser.execute(%{"action" => "status"}, %{})

      assert is_map(result)
      assert Map.has_key?(result, :status)
      assert result.status in ["stopped", "running", "starting"]
    end
  end

  describe "execute/2 - stop action" do
    test "returns appropriate message when browser is not running" do
      {:ok, result} = Browser.execute(%{"action" => "stop"}, %{})

      # 可能是 "stopped" 或 "not_running"
      assert result.status in ["stopped", "not_running"]
    end
  end

  describe "execute/2 - tabs action" do
    test "returns error when browser is not running" do
      {:error, message} = Browser.execute(%{"action" => "tabs"}, %{})

      assert String.contains?(message, "not running")
    end
  end

  describe "execute/2 - open action" do
    test "returns error when browser is not running" do
      {:error, message} = Browser.execute(%{"action" => "open", "url" => "https://example.com"}, %{})

      assert String.contains?(message, "not running")
    end
  end

  describe "execute/2 - close action" do
    test "returns error when targetId is missing" do
      # 先启动浏览器
      {:error, message} = Browser.execute(%{"action" => "close"}, %{})

      assert String.contains?(message, "targetId") or String.contains?(message, "not running")
    end
  end

  describe "execute/2 - invalid action" do
    test "returns error for unknown action" do
      {:error, message} = Browser.execute(%{"action" => "invalid_action"}, %{})

      assert String.contains?(message, "Unknown action")
    end
  end

  describe "execute/2 - navigate action" do
    test "returns error when missing required parameters" do
      {:error, message} = Browser.execute(%{"action" => "navigate"}, %{})

      assert String.contains?(message, "targetId") or String.contains?(message, "not running")
    end
  end
end
