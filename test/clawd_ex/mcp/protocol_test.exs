defmodule ClawdEx.MCP.ProtocolTest do
  use ExUnit.Case, async: true

  alias ClawdEx.MCP.Protocol

  # ============================================================================
  # Encoding
  # ============================================================================

  describe "encode_request/3" do
    test "encodes a basic request" do
      assert {:ok, json} = Protocol.encode_request("tools/list", %{}, 1)
      decoded = Jason.decode!(json)

      assert decoded["jsonrpc"] == "2.0"
      assert decoded["id"] == 1
      assert decoded["method"] == "tools/list"
    end

    test "encodes a request with params" do
      params = %{"name" => "echo", "arguments" => %{"text" => "hello"}}
      assert {:ok, json} = Protocol.encode_request("tools/call", params, 42)
      decoded = Jason.decode!(json)

      assert decoded["id"] == 42
      assert decoded["method"] == "tools/call"
      assert decoded["params"]["name"] == "echo"
      assert decoded["params"]["arguments"]["text"] == "hello"
    end
  end

  describe "encode_notification/2" do
    test "encodes a notification (no id)" do
      assert {:ok, json} = Protocol.encode_notification("notifications/initialized")
      decoded = Jason.decode!(json)

      assert decoded["jsonrpc"] == "2.0"
      assert decoded["method"] == "notifications/initialized"
      refute Map.has_key?(decoded, "id")
    end

    test "encodes a notification with params" do
      assert {:ok, json} = Protocol.encode_notification("some/event", %{"key" => "value"})
      decoded = Jason.decode!(json)

      assert decoded["method"] == "some/event"
      assert decoded["params"]["key"] == "value"
      refute Map.has_key?(decoded, "id")
    end
  end

  # ============================================================================
  # Decoding
  # ============================================================================

  describe "decode/1" do
    test "decodes a successful response" do
      json = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "result" => %{"tools" => []}})
      assert {:ok, %{type: :response, id: 1, result: %{"tools" => []}}} = Protocol.decode(json)
    end

    test "decodes an error response" do
      json = Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 2,
        "error" => %{"code" => -32600, "message" => "Invalid Request"}
      })
      assert {:ok, %{type: :error, id: 2, error: %{code: -32600, message: "Invalid Request"}}} = Protocol.decode(json)
    end

    test "decodes a server request" do
      json = Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 5,
        "method" => "sampling/createMessage",
        "params" => %{"prompt" => "hello"}
      })
      assert {:ok, %{type: :request, id: 5, method: "sampling/createMessage", params: %{"prompt" => "hello"}}} = Protocol.decode(json)
    end

    test "decodes a notification" do
      json = Jason.encode!(%{
        "jsonrpc" => "2.0",
        "method" => "notifications/tools/list_changed"
      })
      assert {:ok, %{type: :notification, method: "notifications/tools/list_changed"}} = Protocol.decode(json)
    end

    test "handles invalid JSON" do
      assert {:error, _} = Protocol.decode("not json at all")
    end

    test "handles missing jsonrpc field" do
      json = Jason.encode!(%{"random" => "data"})
      assert {:error, :invalid_jsonrpc} = Protocol.decode(json)
    end

    test "handles non-binary input" do
      assert {:error, :invalid_input} = Protocol.decode(123)
    end
  end

  # ============================================================================
  # MCP Message Constructors
  # ============================================================================

  describe "initialize/2" do
    test "builds a proper initialize request" do
      assert {:ok, json} = Protocol.initialize(1)
      decoded = Jason.decode!(json)

      assert decoded["method"] == "initialize"
      assert decoded["id"] == 1
      assert decoded["params"]["protocolVersion"] == "2024-11-05"
      assert decoded["params"]["clientInfo"]["name"] == "clawd_ex"
      assert Map.has_key?(decoded["params"], "capabilities")
    end

    test "merges custom client info" do
      assert {:ok, json} = Protocol.initialize(1, %{"name" => "MyClient", "extra" => "data"})
      decoded = Jason.decode!(json)

      assert decoded["params"]["clientInfo"]["name"] == "MyClient"
      assert decoded["params"]["clientInfo"]["extra"] == "data"
    end
  end

  describe "initialized/0" do
    test "builds initialized notification" do
      assert {:ok, json} = Protocol.initialized()
      decoded = Jason.decode!(json)

      assert decoded["method"] == "notifications/initialized"
      refute Map.has_key?(decoded, "id")
    end
  end

  describe "tools_list/2" do
    test "builds tools/list request" do
      assert {:ok, json} = Protocol.tools_list(3)
      decoded = Jason.decode!(json)

      assert decoded["method"] == "tools/list"
      assert decoded["id"] == 3
    end
  end

  describe "tools_call/3" do
    test "builds tools/call request" do
      assert {:ok, json} = Protocol.tools_call(7, "read_file", %{"path" => "/tmp/test.txt"})
      decoded = Jason.decode!(json)

      assert decoded["method"] == "tools/call"
      assert decoded["id"] == 7
      assert decoded["params"]["name"] == "read_file"
      assert decoded["params"]["arguments"]["path"] == "/tmp/test.txt"
    end

    test "builds tools/call with empty arguments" do
      assert {:ok, json} = Protocol.tools_call(8, "list_files")
      decoded = Jason.decode!(json)

      assert decoded["params"]["name"] == "list_files"
      assert decoded["params"]["arguments"] == %{}
    end
  end

  describe "ping/1" do
    test "builds a ping request" do
      assert {:ok, json} = Protocol.ping(99)
      decoded = Jason.decode!(json)

      assert decoded["method"] == "ping"
      assert decoded["id"] == 99
    end
  end

  # ============================================================================
  # Round-trip
  # ============================================================================

  describe "roundtrip encoding/decoding" do
    test "encode request then decode as request" do
      assert {:ok, _json} = Protocol.encode_request("test/method", %{"key" => "val"}, 42)

      # Simulate server responding
      response = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 42, "result" => %{"status" => "ok"}})
      assert {:ok, %{type: :response, id: 42, result: %{"status" => "ok"}}} = Protocol.decode(response)
    end
  end
end
