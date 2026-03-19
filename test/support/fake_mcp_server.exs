#!/usr/bin/env elixir
# Fake MCP Server for testing
#
# Reads JSON-RPC 2.0 messages from stdin, returns fixed responses to stdout.
# Supports: initialize, tools/list, tools/call, ping
#
# Uses :json module (Erlang/OTP 27+) for JSON encoding/decoding.
# Falls back to a minimal JSON implementation for older OTP versions.
#
# Usage: elixir test/support/fake_mcp_server.exs [--slow] [--fail-init] [--fail-tools]

defmodule SimpleJSON do
  @moduledoc "Minimal JSON encoder/decoder for standalone scripts (no Jason dependency)"

  # Decode
  def decode(str) when is_binary(str) do
    try do
      # Use Erlang :json module (OTP 27+)
      {:ok, :json.decode(str)}
    rescue
      _ ->
        {:error, :decode_failed}
    end
  end

  # Encode
  def encode(term) do
    try do
      {:ok, :erlang.iolist_to_binary(:json.encode(term))}
    rescue
      _ ->
        {:error, :encode_failed}
    end
  end

  def encode!(term) do
    case encode(term) do
      {:ok, json} -> json
      {:error, reason} -> raise "JSON encode failed: #{inspect(reason)}"
    end
  end
end

defmodule FakeMCPServer do
  @tools [
    %{
      "name" => "echo",
      "description" => "Echo back the input",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "message" => %{"type" => "string", "description" => "Message to echo"}
        },
        "required" => ["message"]
      }
    },
    %{
      "name" => "add",
      "description" => "Add two numbers",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "a" => %{"type" => "number"},
          "b" => %{"type" => "number"}
        },
        "required" => ["a", "b"]
      }
    }
  ]

  def run(opts \\ []) do
    slow = Keyword.get(opts, :slow, false)
    fail_init = Keyword.get(opts, :fail_init, false)
    fail_tools = Keyword.get(opts, :fail_tools, false)

    loop(%{slow: slow, fail_init: fail_init, fail_tools: fail_tools})
  end

  defp loop(opts) do
    case IO.read(:stdio, :line) do
      :eof ->
        :ok

      {:error, _} ->
        :ok

      line ->
        line = String.trim(line)

        if line != "" do
          handle_line(line, opts)
        end

        loop(opts)
    end
  end

  defp handle_line(line, opts) do
    case SimpleJSON.decode(line) do
      {:ok, msg} ->
        if opts.slow, do: Process.sleep(100)
        handle_message(msg, opts)

      {:error, _} ->
        # Ignore malformed JSON
        :ok
    end
  end

  defp handle_message(%{"method" => "initialize", "id" => id}, %{fail_init: true}) do
    error_response(id, -32600, "Initialization failed")
  end

  defp handle_message(%{"method" => "initialize", "id" => id}, _opts) do
    result = %{
      "protocolVersion" => "2024-11-05",
      "capabilities" => %{
        "tools" => %{}
      },
      "serverInfo" => %{
        "name" => "fake-mcp-server",
        "version" => "1.0.0"
      }
    }

    send_response(id, result)
  end

  defp handle_message(%{"method" => "notifications/initialized"}, _opts) do
    # Notification — no response needed
    :ok
  end

  defp handle_message(%{"method" => "tools/list", "id" => id}, %{fail_tools: true}) do
    error_response(id, -32600, "Tools listing failed")
  end

  defp handle_message(%{"method" => "tools/list", "id" => id}, _opts) do
    send_response(id, %{"tools" => @tools})
  end

  defp handle_message(%{"method" => "tools/call", "id" => id, "params" => params}, _opts) do
    tool_name = params["name"]
    arguments = params["arguments"] || %{}

    result = execute_tool(tool_name, arguments)
    send_response(id, result)
  end

  defp handle_message(%{"method" => "ping", "id" => id}, _opts) do
    send_response(id, %{})
  end

  defp handle_message(%{"method" => method, "id" => id}, _opts) do
    error_response(id, -32601, "Method not found: #{method}")
  end

  defp handle_message(_msg, _opts) do
    # Ignore unknown messages (e.g., notifications we don't handle)
    :ok
  end

  defp execute_tool("echo", %{"message" => message}) do
    %{
      "content" => [
        %{"type" => "text", "text" => message}
      ]
    }
  end

  defp execute_tool("add", %{"a" => a, "b" => b}) do
    %{
      "content" => [
        %{"type" => "text", "text" => to_string(a + b)}
      ]
    }
  end

  defp execute_tool(name, _args) do
    %{
      "content" => [
        %{"type" => "text", "text" => "Unknown tool: #{name}"}
      ],
      "isError" => true
    }
  end

  defp send_response(id, result) do
    msg = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => result
    }

    json = SimpleJSON.encode!(msg)
    IO.puts(json)
  end

  defp error_response(id, code, message) do
    msg = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{
        "code" => code,
        "message" => message
      }
    }

    json = SimpleJSON.encode!(msg)
    IO.puts(json)
  end
end

# Parse CLI args
args = System.argv()
opts = [
  slow: "--slow" in args,
  fail_init: "--fail-init" in args,
  fail_tools: "--fail-tools" in args
]

FakeMCPServer.run(opts)
