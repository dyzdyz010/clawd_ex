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
      assert String.contains?(desc, "browser")
    end
  end

  describe "parameters/0" do
    test "returns valid parameter schema" do
      params = Browser.parameters()
      assert params[:type] == "object"
      assert is_map(params[:properties])
      assert params[:properties][:action]
      assert params[:properties][:url]
      assert params[:properties][:snapshotFormat]
      assert params[:properties][:request]
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
      assert "snapshot" in actions
      assert "screenshot" in actions
      assert "console" in actions

      # Interactive actions
      assert "act" in actions
      assert "evaluate" in actions
      assert "upload" in actions
      assert "dialog" in actions
    end

    test "request parameter has correct structure" do
      params = Browser.parameters()
      request = params[:properties][:request]

      assert request[:type] == "object"
      assert request[:properties][:kind]
      assert request[:properties][:ref]
      assert request[:properties][:text]
      assert request[:properties][:key]
      assert request[:properties][:values]
      assert request[:properties][:fields]

      # Check kind enum
      kinds = request[:properties][:kind][:enum]
      assert "click" in kinds
      assert "type" in kinds
      assert "press" in kinds
      assert "hover" in kinds
      assert "select" in kinds
      assert "fill" in kinds
      assert "drag" in kinds
      assert "wait" in kinds
    end
  end

  describe "execute/2 - navigate" do
    test "requires url parameter" do
      assert {:error, msg} = Browser.execute(%{"action" => "navigate", "targetId" => "t1"}, %{})
      assert String.contains?(msg, "url")
    end

    test "requires targetId parameter" do
      assert {:error, msg} =
               Browser.execute(%{"action" => "navigate", "url" => "https://example.com"}, %{})

      assert String.contains?(msg, "targetId")
    end
  end

  describe "execute/2 - act" do
    test "requires targetId parameter" do
      assert {:error, msg} =
               Browser.execute(
                 %{
                   "action" => "act",
                   "request" => %{"kind" => "click", "ref" => "e1"}
                 },
                 %{}
               )

      assert String.contains?(msg, "targetId")
    end

    test "requires request parameter" do
      assert {:error, msg} =
               Browser.execute(
                 %{
                   "action" => "act",
                   "targetId" => "t1"
                 },
                 %{}
               )

      assert String.contains?(msg, "request")
    end

    test "requires kind in request" do
      assert {:error, msg} =
               Browser.execute(
                 %{
                   "action" => "act",
                   "targetId" => "t1",
                   "request" => %{}
                 },
                 %{}
               )

      assert String.contains?(msg, "kind")
    end

    test "click requires ref" do
      assert {:error, msg} =
               Browser.execute(
                 %{
                   "action" => "act",
                   "targetId" => "t1",
                   "request" => %{"kind" => "click"}
                 },
                 %{}
               )

      assert String.contains?(msg, "ref")
    end

    test "type requires ref and text" do
      assert {:error, msg} =
               Browser.execute(
                 %{
                   "action" => "act",
                   "targetId" => "t1",
                   "request" => %{"kind" => "type", "ref" => "e1"}
                 },
                 %{}
               )

      assert String.contains?(msg, "text")

      assert {:error, msg2} =
               Browser.execute(
                 %{
                   "action" => "act",
                   "targetId" => "t1",
                   "request" => %{"kind" => "type", "text" => "hello"}
                 },
                 %{}
               )

      assert String.contains?(msg2, "ref")
    end

    test "press requires key" do
      assert {:error, msg} =
               Browser.execute(
                 %{
                   "action" => "act",
                   "targetId" => "t1",
                   "request" => %{"kind" => "press"}
                 },
                 %{}
               )

      assert String.contains?(msg, "key")
    end

    test "hover requires ref" do
      assert {:error, msg} =
               Browser.execute(
                 %{
                   "action" => "act",
                   "targetId" => "t1",
                   "request" => %{"kind" => "hover"}
                 },
                 %{}
               )

      assert String.contains?(msg, "ref")
    end

    test "select requires ref and values" do
      assert {:error, msg} =
               Browser.execute(
                 %{
                   "action" => "act",
                   "targetId" => "t1",
                   "request" => %{"kind" => "select", "ref" => "e1"}
                 },
                 %{}
               )

      assert String.contains?(msg, "values")

      assert {:error, msg2} =
               Browser.execute(
                 %{
                   "action" => "act",
                   "targetId" => "t1",
                   "request" => %{"kind" => "select", "values" => ["a"]}
                 },
                 %{}
               )

      assert String.contains?(msg2, "ref")
    end

    test "fill requires fields" do
      assert {:error, msg} =
               Browser.execute(
                 %{
                   "action" => "act",
                   "targetId" => "t1",
                   "request" => %{"kind" => "fill"}
                 },
                 %{}
               )

      assert String.contains?(msg, "fields")

      assert {:error, msg2} =
               Browser.execute(
                 %{
                   "action" => "act",
                   "targetId" => "t1",
                   "request" => %{"kind" => "fill", "fields" => []}
                 },
                 %{}
               )

      assert String.contains?(msg2, "fields")
    end

    test "drag requires startRef and endRef" do
      assert {:error, msg} =
               Browser.execute(
                 %{
                   "action" => "act",
                   "targetId" => "t1",
                   "request" => %{"kind" => "drag", "endRef" => "e2"}
                 },
                 %{}
               )

      assert String.contains?(msg, "startRef")

      assert {:error, msg2} =
               Browser.execute(
                 %{
                   "action" => "act",
                   "targetId" => "t1",
                   "request" => %{"kind" => "drag", "startRef" => "e1"}
                 },
                 %{}
               )

      assert String.contains?(msg2, "endRef")
    end

    test "wait requires no parameters" do
      # This won't error on validation, only on execution (browser not running)
      assert {:error, msg} =
               Browser.execute(
                 %{
                   "action" => "act",
                   "targetId" => "t1",
                   "request" => %{"kind" => "wait"}
                 },
                 %{}
               )

      # Should fail because browser not running, not validation
      assert String.contains?(msg, "Browser is not running")
    end

    test "merges top-level ref into request" do
      # If ref is at top level and not in request, it should be merged
      # This won't actually execute (browser not running) but validates structure
      assert {:error, msg} =
               Browser.execute(
                 %{
                   "action" => "act",
                   "targetId" => "t1",
                   "ref" => "button:Submit",
                   "request" => %{"kind" => "click"}
                 },
                 %{}
               )

      # Should fail because browser not running, not validation
      assert String.contains?(msg, "Browser is not running")
    end
  end

  describe "execute/2 - evaluate" do
    test "requires targetId parameter" do
      assert {:error, msg} =
               Browser.execute(
                 %{
                   "action" => "evaluate",
                   "javaScript" => "1+1"
                 },
                 %{}
               )

      assert String.contains?(msg, "targetId")
    end

    test "requires javaScript parameter" do
      assert {:error, msg} =
               Browser.execute(
                 %{
                   "action" => "evaluate",
                   "targetId" => "t1"
                 },
                 %{}
               )

      assert String.contains?(msg, "javaScript")
    end
  end

  describe "execute/2 - upload" do
    test "requires targetId parameter" do
      assert {:error, msg} =
               Browser.execute(
                 %{
                   "action" => "upload",
                   "ref" => "input:file",
                   "paths" => ["/tmp/test.txt"]
                 },
                 %{}
               )

      assert String.contains?(msg, "targetId")
    end

    test "requires ref parameter" do
      assert {:error, msg} =
               Browser.execute(
                 %{
                   "action" => "upload",
                   "targetId" => "t1",
                   "paths" => ["/tmp/test.txt"]
                 },
                 %{}
               )

      assert String.contains?(msg, "ref")
    end

    test "requires paths parameter" do
      assert {:error, msg} =
               Browser.execute(
                 %{
                   "action" => "upload",
                   "targetId" => "t1",
                   "ref" => "input:file"
                 },
                 %{}
               )

      assert String.contains?(msg, "paths")
    end

    test "validates file paths exist" do
      assert {:error, msg} =
               Browser.execute(
                 %{
                   "action" => "upload",
                   "targetId" => "t1",
                   "ref" => "input:file",
                   "paths" => ["/nonexistent/path/file.txt"]
                 },
                 %{}
               )

      assert String.contains?(msg, "not found")
    end

    test "accepts valid file paths" do
      # Create temp file
      temp_path = Path.join(System.tmp_dir!(), "browser_test_#{:rand.uniform(10000)}.txt")
      File.write!(temp_path, "test")

      result =
        Browser.execute(
          %{
            "action" => "upload",
            "targetId" => "t1",
            "ref" => "input:file",
            "paths" => [temp_path]
          },
          %{}
        )

      File.rm(temp_path)

      # Should fail because browser not running, not file validation
      assert {:error, msg} = result
      assert String.contains?(msg, "Browser is not running")
    end
  end

  describe "execute/2 - dialog" do
    test "requires targetId parameter" do
      assert {:error, msg} =
               Browser.execute(
                 %{
                   "action" => "dialog",
                   "accept" => true
                 },
                 %{}
               )

      assert String.contains?(msg, "targetId")
    end

    test "defaults accept to true" do
      # This tests that dialog action doesn't fail on missing accept
      # It will fail on browser not running
      assert {:error, msg} =
               Browser.execute(
                 %{
                   "action" => "dialog",
                   "targetId" => "t1"
                 },
                 %{}
               )

      assert String.contains?(msg, "Browser is not running")
    end
  end

  describe "execute/2 - unknown action" do
    test "returns error for unknown action" do
      assert {:error, msg} = Browser.execute(%{"action" => "unknown"}, %{})
      assert String.contains?(msg, "Unknown action")
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

  # Note: Full integration tests with actual browser server would require
  # starting the browser. These are unit tests that verify the module
  # structure and parameter validation.
end
