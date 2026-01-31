defmodule ClawdEx.Tools.CanvasTest do
  use ExUnit.Case, async: true

  alias ClawdEx.Tools.Canvas

  describe "metadata" do
    test "name returns 'canvas'" do
      assert Canvas.name() == "canvas"
    end

    test "description is not empty" do
      desc = Canvas.description()
      assert is_binary(desc)
      assert String.length(desc) > 0
    end

    test "parameters returns valid schema" do
      params = Canvas.parameters()
      assert is_map(params)
      assert params.type == "object"
      assert Map.has_key?(params.properties, :action)
    end

    test "all actions are defined in parameters" do
      params = Canvas.parameters()
      action_enum = params.properties.action.enum

      expected_actions = [
        "present",
        "hide",
        "navigate",
        "eval",
        "snapshot",
        "a2ui_push",
        "a2ui_reset"
      ]

      for action <- expected_actions do
        assert action in action_enum, "Missing action: #{action}"
      end
    end
  end

  describe "execute/2 validation" do
    test "returns error for unknown action" do
      result = Canvas.execute(%{"action" => "unknown_action"}, %{})
      assert {:error, msg} = result
      assert msg =~ "Unknown action"
    end

    test "returns error when url is missing for present" do
      result = Canvas.execute(%{"action" => "present"}, %{})
      assert {:error, msg} = result
      assert msg =~ "url parameter is required"
    end

    test "returns error when url is missing for navigate" do
      result = Canvas.execute(%{"action" => "navigate"}, %{})
      assert {:error, msg} = result
      assert msg =~ "url parameter is required"
    end

    test "returns error when javaScript is missing for eval" do
      result = Canvas.execute(%{"action" => "eval"}, %{})
      assert {:error, msg} = result
      assert msg =~ "javaScript parameter is required"
    end

    test "returns error when jsonl/jsonlPath is missing for a2ui_push" do
      result = Canvas.execute(%{"action" => "a2ui_push"}, %{})
      assert {:error, msg} = result
      assert msg =~ "jsonl or jsonlPath parameter is required"
    end
  end

  describe "parameter handling" do
    test "accepts string keys" do
      result = Canvas.execute(%{"action" => "present", "url" => "https://example.com"}, %{})
      # Should not complain about missing url
      refute match?({:error, "url parameter is required" <> _}, result)
    end

    test "accepts atom keys" do
      result = Canvas.execute(%{action: "present", url: "https://example.com"}, %{})
      refute match?({:error, "url parameter is required" <> _}, result)
    end
  end

  describe "gateway URL configuration" do
    test "uses default gateway URL when not specified" do
      result = Canvas.execute(%{"action" => "hide"}, %{})
      # Should return connection error (no gateway running), not crash
      assert match?({:error, _}, result)
    end

    test "uses gateway URL from params" do
      result =
        Canvas.execute(
          %{"action" => "hide", "gatewayUrl" => "http://custom:3030"},
          %{}
        )

      assert match?({:error, _}, result)
    end

    test "uses gateway URL from context" do
      result =
        Canvas.execute(
          %{"action" => "hide"},
          %{gateway_url: "http://context:3030"}
        )

      assert match?({:error, _}, result)
    end
  end

  describe "present action parameters" do
    test "accepts all parameters for present" do
      result =
        Canvas.execute(
          %{
            "action" => "present",
            "url" => "https://example.com",
            "node" => "test-node",
            "target" => "main",
            "width" => 800,
            "height" => 600,
            "maxWidth" => 1920,
            "x" => 100,
            "y" => 50
          },
          %{}
        )

      # Should fail at gateway connection, not validation
      assert match?({:error, msg} when is_binary(msg), result)
      refute match?({:error, "url parameter is required" <> _}, result)
    end
  end

  describe "hide action" do
    test "hide works without required params" do
      result =
        Canvas.execute(
          %{
            "action" => "hide",
            "node" => "test-node"
          },
          %{}
        )

      # Should fail at gateway connection, not validation
      assert match?({:error, _}, result)
    end
  end

  describe "navigate action" do
    test "navigate requires url" do
      result = Canvas.execute(%{"action" => "navigate"}, %{})
      assert {:error, msg} = result
      assert msg =~ "url parameter is required"
    end

    test "navigate accepts url" do
      result =
        Canvas.execute(
          %{
            "action" => "navigate",
            "url" => "https://example.com/new-page",
            "node" => "test-node"
          },
          %{}
        )

      refute match?({:error, "url parameter is required" <> _}, result)
    end
  end

  describe "eval action" do
    test "eval requires javaScript" do
      result = Canvas.execute(%{"action" => "eval"}, %{})
      assert {:error, msg} = result
      assert msg =~ "javaScript parameter is required"
    end

    test "eval accepts javaScript code" do
      result =
        Canvas.execute(
          %{
            "action" => "eval",
            "javaScript" => "document.title",
            "node" => "test-node"
          },
          %{}
        )

      refute match?({:error, "javaScript parameter is required" <> _}, result)
    end
  end

  describe "snapshot action" do
    test "snapshot works without required params" do
      result =
        Canvas.execute(
          %{
            "action" => "snapshot",
            "node" => "test-node"
          },
          %{}
        )

      # Should fail at gateway connection, not validation
      assert match?({:error, _}, result)
    end

    test "snapshot accepts all parameters" do
      result =
        Canvas.execute(
          %{
            "action" => "snapshot",
            "node" => "test-node",
            "target" => "main",
            "width" => 1920,
            "height" => 1080,
            "outputFormat" => "png",
            "quality" => 90,
            "delayMs" => 500
          },
          %{}
        )

      assert match?({:error, _}, result)
    end
  end

  describe "a2ui_push action" do
    test "a2ui_push requires jsonl or jsonlPath" do
      result = Canvas.execute(%{"action" => "a2ui_push"}, %{})
      assert {:error, msg} = result
      assert msg =~ "jsonl or jsonlPath parameter is required"
    end

    test "a2ui_push accepts jsonl content" do
      jsonl = ~s({"type": "text", "content": "Hello"}\n{"type": "button", "label": "Click"})

      result =
        Canvas.execute(
          %{
            "action" => "a2ui_push",
            "jsonl" => jsonl,
            "node" => "test-node"
          },
          %{}
        )

      refute match?({:error, "jsonl or jsonlPath parameter is required" <> _}, result)
    end

    test "a2ui_push returns error for non-existent file" do
      result =
        Canvas.execute(
          %{
            "action" => "a2ui_push",
            "jsonlPath" => "/non/existent/file.jsonl",
            "node" => "test-node"
          },
          %{}
        )

      assert {:error, msg} = result
      assert msg =~ "Failed to read JSONL file"
    end
  end

  describe "a2ui_reset action" do
    test "a2ui_reset works without required params" do
      result =
        Canvas.execute(
          %{
            "action" => "a2ui_reset",
            "node" => "test-node"
          },
          %{}
        )

      # Should fail at gateway connection, not validation
      assert match?({:error, _}, result)
    end
  end

  describe "timeout configuration" do
    test "accepts custom timeout" do
      result =
        Canvas.execute(
          %{
            "action" => "hide",
            "timeoutMs" => 5000
          },
          %{}
        )

      assert match?({:error, _}, result)
    end
  end
end
