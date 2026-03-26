defmodule ClawdEx.Tools.CanvasTest do
  use ExUnit.Case, async: true

  alias ClawdEx.Tools.Canvas

  describe "execute/2 validation" do
    test "returns error for unknown action" do
      assert {:error, msg} = Canvas.execute(%{"action" => "unknown_action"}, %{})
      assert msg =~ "Unknown action"
    end

    test "validates required params per action" do
      # present requires url
      assert {:error, msg} = Canvas.execute(%{"action" => "present"}, %{})
      assert msg =~ "url parameter is required"

      # navigate requires url
      assert {:error, msg} = Canvas.execute(%{"action" => "navigate"}, %{})
      assert msg =~ "url parameter is required"

      # eval requires javaScript
      assert {:error, msg} = Canvas.execute(%{"action" => "eval"}, %{})
      assert msg =~ "javaScript parameter is required"

      # a2ui_push requires jsonl or jsonlPath
      assert {:error, msg} = Canvas.execute(%{"action" => "a2ui_push"}, %{})
      assert msg =~ "jsonl or jsonlPath parameter is required"
    end
  end

  describe "parameter handling" do
    test "accepts both string and atom keys" do
      result_str = Canvas.execute(%{"action" => "present", "url" => "https://example.com"}, %{})
      refute match?({:error, "url parameter is required" <> _}, result_str)

      result_atom = Canvas.execute(%{action: "present", url: "https://example.com"}, %{})
      refute match?({:error, "url parameter is required" <> _}, result_atom)
    end
  end

  describe "gateway URL configuration" do
    test "uses gateway URL from params or context without crashing" do
      # All fail at gateway connection level, not validation
      assert {:error, _} = Canvas.execute(%{"action" => "hide"}, %{})
      assert {:error, _} = Canvas.execute(%{"action" => "hide", "gatewayUrl" => "http://custom:3030"}, %{})
      assert {:error, _} = Canvas.execute(%{"action" => "hide"}, %{gateway_url: "http://context:3030"})
    end
  end

  describe "actions pass validation with correct params" do
    test "present with all params passes validation" do
      result =
        Canvas.execute(
          %{
            "action" => "present",
            "url" => "https://example.com",
            "node" => "test-node",
            "width" => 800,
            "height" => 600
          },
          %{}
        )

      # Fails at gateway connection, not validation
      assert match?({:error, msg} when is_binary(msg), result)
      refute match?({:error, "url parameter is required" <> _}, result)
    end

    test "a2ui_push accepts jsonl content" do
      jsonl = ~s({"type": "text", "content": "Hello"})

      result =
        Canvas.execute(%{"action" => "a2ui_push", "jsonl" => jsonl, "node" => "test"}, %{})

      refute match?({:error, "jsonl or jsonlPath parameter is required" <> _}, result)
    end

    test "a2ui_push returns error for non-existent file" do
      result =
        Canvas.execute(
          %{"action" => "a2ui_push", "jsonlPath" => "/non/existent/file.jsonl"},
          %{}
        )

      assert {:error, msg} = result
      assert msg =~ "Failed to read JSONL file"
    end
  end
end
