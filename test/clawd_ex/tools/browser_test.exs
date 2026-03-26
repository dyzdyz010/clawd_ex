defmodule ClawdEx.Tools.BrowserTest do
  use ExUnit.Case, async: true

  alias ClawdEx.Tools.Browser

  @moduletag :browser

  describe "parameters/0" do
    test "returns valid schema with all supported actions and request kinds" do
      params = Browser.parameters()
      assert params[:type] == "object"
      assert "action" in params[:required]

      actions = params[:properties][:action][:enum]
      for a <- ~w(status start stop tabs open close navigate snapshot screenshot console act evaluate upload dialog) do
        assert a in actions, "Missing action: #{a}"
      end

      request = params[:properties][:request]
      assert request[:type] == "object"
      kinds = request[:properties][:kind][:enum]
      for k <- ~w(click type press hover select fill drag wait) do
        assert k in kinds, "Missing kind: #{k}"
      end
    end
  end

  describe "execute/2 - navigate validation" do
    test "requires both url and targetId" do
      assert {:error, msg1} = Browser.execute(%{"action" => "navigate", "targetId" => "t1"}, %{})
      assert msg1 =~ "url"

      assert {:error, msg2} = Browser.execute(%{"action" => "navigate", "url" => "https://example.com"}, %{})
      assert msg2 =~ "targetId"
    end
  end

  describe "execute/2 - act validation" do
    test "requires targetId and request with kind" do
      assert {:error, msg1} =
               Browser.execute(%{"action" => "act", "request" => %{"kind" => "click", "ref" => "e1"}}, %{})
      assert msg1 =~ "targetId"

      assert {:error, msg2} = Browser.execute(%{"action" => "act", "targetId" => "t1"}, %{})
      assert msg2 =~ "request"

      assert {:error, msg3} = Browser.execute(%{"action" => "act", "targetId" => "t1", "request" => %{}}, %{})
      assert msg3 =~ "kind"
    end

    test "validates required fields for each act kind" do
      base = %{"action" => "act", "targetId" => "t1"}

      # click requires ref
      assert {:error, msg} = Browser.execute(Map.put(base, "request", %{"kind" => "click"}), %{})
      assert msg =~ "ref"

      # type requires ref and text
      assert {:error, msg} = Browser.execute(Map.put(base, "request", %{"kind" => "type", "ref" => "e1"}), %{})
      assert msg =~ "text"
      assert {:error, msg} = Browser.execute(Map.put(base, "request", %{"kind" => "type", "text" => "hi"}), %{})
      assert msg =~ "ref"

      # press requires key
      assert {:error, msg} = Browser.execute(Map.put(base, "request", %{"kind" => "press"}), %{})
      assert msg =~ "key"

      # hover requires ref
      assert {:error, msg} = Browser.execute(Map.put(base, "request", %{"kind" => "hover"}), %{})
      assert msg =~ "ref"

      # select requires ref and values
      assert {:error, msg} = Browser.execute(Map.put(base, "request", %{"kind" => "select", "ref" => "e1"}), %{})
      assert msg =~ "values"
      assert {:error, msg} = Browser.execute(Map.put(base, "request", %{"kind" => "select", "values" => ["a"]}), %{})
      assert msg =~ "ref"

      # fill requires non-empty fields
      assert {:error, msg} = Browser.execute(Map.put(base, "request", %{"kind" => "fill"}), %{})
      assert msg =~ "fields"
      assert {:error, msg} = Browser.execute(Map.put(base, "request", %{"kind" => "fill", "fields" => []}), %{})
      assert msg =~ "fields"

      # drag requires startRef and endRef
      assert {:error, msg} = Browser.execute(Map.put(base, "request", %{"kind" => "drag", "endRef" => "e2"}), %{})
      assert msg =~ "startRef"
      assert {:error, msg} = Browser.execute(Map.put(base, "request", %{"kind" => "drag", "startRef" => "e1"}), %{})
      assert msg =~ "endRef"

      # wait requires no params - fails at browser level, not validation
      assert {:error, msg} = Browser.execute(Map.put(base, "request", %{"kind" => "wait"}), %{})
      assert msg =~ "Browser is not running"
    end
  end

  describe "execute/2 - upload validation" do
    test "requires targetId, ref, and paths" do
      assert {:error, msg} = Browser.execute(%{"action" => "upload", "ref" => "f", "paths" => ["/tmp/t"]}, %{})
      assert msg =~ "targetId"

      assert {:error, msg} = Browser.execute(%{"action" => "upload", "targetId" => "t1", "paths" => ["/tmp/t"]}, %{})
      assert msg =~ "ref"

      assert {:error, msg} = Browser.execute(%{"action" => "upload", "targetId" => "t1", "ref" => "f"}, %{})
      assert msg =~ "paths"
    end

    test "validates file paths exist" do
      assert {:error, msg} =
               Browser.execute(
                 %{"action" => "upload", "targetId" => "t1", "ref" => "f", "paths" => ["/nonexistent/file.txt"]},
                 %{}
               )
      assert msg =~ "not found"
    end
  end

  describe "execute/2 - evaluate validation" do
    test "requires targetId and javaScript" do
      assert {:error, msg} = Browser.execute(%{"action" => "evaluate", "javaScript" => "1+1"}, %{})
      assert msg =~ "targetId"

      assert {:error, msg} = Browser.execute(%{"action" => "evaluate", "targetId" => "t1"}, %{})
      assert msg =~ "javaScript"
    end
  end

  describe "execute/2 - unknown action" do
    test "returns error for unknown action" do
      assert {:error, msg} = Browser.execute(%{"action" => "unknown"}, %{})
      assert msg =~ "Unknown action"
    end
  end
end
