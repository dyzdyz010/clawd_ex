defmodule ClawdEx.Tools.BrowserTest do
  use ExUnit.Case, async: true

  alias ClawdEx.Tools.Browser

  @moduletag :browser

  describe "name/0" do
    test "returns browser" do
      assert Browser.name() == "browser"
    end
  end

  describe "description/0" do
    test "returns description string" do
      desc = Browser.description()
      assert is_binary(desc)
      assert String.contains?(desc, "browser") or String.contains?(desc, "Browser")
    end
  end

  describe "parameters/0" do
    test "returns valid parameter schema" do
      params = Browser.parameters()
      assert params[:type] == "object"
      assert is_map(params[:properties])
      assert params[:properties][:action]
      assert params[:properties][:url]
      assert params[:properties][:targetId]
    end

    test "has required action parameter" do
      params = Browser.parameters()
      assert "action" in params[:required]
    end

    test "action enum includes all supported actions" do
      params = Browser.parameters()
      actions = params[:properties][:action][:enum]

      # Basic actions
      assert "status" in actions
      assert "start" in actions
      assert "stop" in actions
      assert "tabs" in actions
      assert "open" in actions
      assert "close" in actions
      assert "navigate" in actions

      # Page operations
      assert "snapshot" in actions
      assert "screenshot" in actions
      assert "console" in actions
    end

    test "has snapshot format parameter" do
      params = Browser.parameters()
      snapshot_format = params[:properties][:snapshotFormat]

      assert snapshot_format[:type] == "string"
      assert "aria" in snapshot_format[:enum]
      assert "ai" in snapshot_format[:enum]
    end

    test "has screenshot parameters" do
      params = Browser.parameters()

      assert params[:properties][:fullPage][:type] == "boolean"
      assert params[:properties][:type][:enum] == ["png", "jpeg"]
      assert params[:properties][:quality][:type] == "integer"
    end

    test "has console parameters" do
      params = Browser.parameters()

      assert params[:properties][:level]
      assert "error" in params[:properties][:level][:enum]
      assert "warning" in params[:properties][:level][:enum]
      assert params[:properties][:limit][:type] == "integer"
    end
  end

  describe "execute/2 - navigate" do
    test "requires targetId parameter" do
      assert {:error, msg} = Browser.execute(%{"action" => "navigate", "url" => "https://example.com"}, %{})
      assert String.contains?(msg, "targetId")
    end

    test "requires url parameter" do
      assert {:error, msg} = Browser.execute(%{"action" => "navigate", "targetId" => "abc123"}, %{})
      assert String.contains?(msg, "url")
    end
  end

  describe "execute/2 - snapshot" do
    test "requires targetId parameter" do
      assert {:error, msg} = Browser.execute(%{"action" => "snapshot"}, %{})
      assert String.contains?(msg, "targetId")
    end
  end

  describe "execute/2 - screenshot" do
    test "requires targetId parameter" do
      assert {:error, msg} = Browser.execute(%{"action" => "screenshot"}, %{})
      assert String.contains?(msg, "targetId")
    end
  end

  describe "execute/2 - console" do
    test "requires targetId parameter" do
      assert {:error, msg} = Browser.execute(%{"action" => "console"}, %{})
      assert String.contains?(msg, "targetId")
    end
  end

  describe "execute/2 - unknown action" do
    test "returns error for unknown action" do
      assert {:error, msg} = Browser.execute(%{"action" => "unknown"}, %{})
      assert String.contains?(msg, "Unknown action")
    end

    test "error message lists valid actions" do
      {:error, msg} = Browser.execute(%{"action" => "invalid"}, %{})
      assert String.contains?(msg, "snapshot")
      assert String.contains?(msg, "screenshot")
      assert String.contains?(msg, "console")
    end
  end

  describe "integration with Registry" do
    test "browser tool is properly structured for registry" do
      assert Browser.name() |> is_binary()
      assert Browser.description() |> is_binary()
      assert Browser.parameters() |> is_map()

      params = Browser.parameters()
      assert params[:type] == "object"
      assert is_map(params[:properties])
      assert is_list(params[:required])
    end
  end

  # Note: Full integration tests with actual browser would require
  # a running browser and are better suited for integration test suite.
  # These tests verify the module structure and parameter validation.
end
