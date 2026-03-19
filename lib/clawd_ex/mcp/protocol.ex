defmodule ClawdEx.MCP.Protocol do
  @moduledoc """
  MCP (Model Context Protocol) JSON-RPC 2.0 encoding/decoding.

  Handles serialization and deserialization of JSON-RPC 2.0 messages
  used by the MCP protocol, including request, response, notification,
  and error message types.
  """

  @type request_id :: integer() | String.t()

  @type request :: %{
          jsonrpc: String.t(),
          id: request_id(),
          method: String.t(),
          params: map()
        }

  @type notification :: %{
          jsonrpc: String.t(),
          method: String.t(),
          params: map()
        }

  @type response :: %{
          jsonrpc: String.t(),
          id: request_id(),
          result: any()
        }

  @type error_response :: %{
          jsonrpc: String.t(),
          id: request_id() | nil,
          error: %{code: integer(), message: String.t(), data: any()}
        }

  # ============================================================================
  # Encoding
  # ============================================================================

  @doc "Encode a JSON-RPC 2.0 request"
  @spec encode_request(String.t(), map(), request_id()) :: {:ok, String.t()} | {:error, term()}
  def encode_request(method, params \\ %{}, id) do
    msg = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => params || %{}
    }

    case Jason.encode(msg) do
      {:ok, json} -> {:ok, json}
      {:error, reason} -> {:error, {:encode_error, reason}}
    end
  end

  @doc "Encode a JSON-RPC 2.0 notification (no id field)"
  @spec encode_notification(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def encode_notification(method, params \\ %{}) do
    msg = %{
      "jsonrpc" => "2.0",
      "method" => method,
      "params" => params || %{}
    }

    case Jason.encode(msg) do
      {:ok, json} -> {:ok, json}
      {:error, reason} -> {:error, {:encode_error, reason}}
    end
  end

  # ============================================================================
  # Decoding
  # ============================================================================

  @doc "Decode a JSON-RPC 2.0 message"
  @spec decode(String.t()) :: {:ok, map()} | {:error, term()}
  def decode(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{"jsonrpc" => "2.0"} = msg} ->
        {:ok, classify_message(msg)}

      {:ok, _} ->
        {:error, :invalid_jsonrpc}

      {:error, %Jason.DecodeError{} = err} ->
        {:error, {:decode_error, Exception.message(err)}}
    end
  end

  def decode(_), do: {:error, :invalid_input}

  # ============================================================================
  # MCP Message Constructors
  # ============================================================================

  @doc "Build an initialize request"
  @spec initialize(request_id(), map()) :: {:ok, String.t()} | {:error, term()}
  def initialize(id, client_info \\ %{}) do
    params = %{
      "protocolVersion" => "2024-11-05",
      "capabilities" => %{},
      "clientInfo" => Map.merge(%{"name" => "clawd_ex", "version" => "0.1.0"}, client_info)
    }

    encode_request("initialize", params, id)
  end

  @doc "Build an initialized notification"
  @spec initialized() :: {:ok, String.t()} | {:error, term()}
  def initialized do
    encode_notification("notifications/initialized")
  end

  @doc "Build a tools/list request"
  @spec tools_list(request_id(), map()) :: {:ok, String.t()} | {:error, term()}
  def tools_list(id, params \\ %{}) do
    encode_request("tools/list", params, id)
  end

  @doc "Build a tools/call request"
  @spec tools_call(request_id(), String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def tools_call(id, tool_name, arguments \\ %{}) do
    params = %{
      "name" => tool_name,
      "arguments" => arguments || %{}
    }

    encode_request("tools/call", params, id)
  end

  @doc "Build a ping request"
  @spec ping(request_id()) :: {:ok, String.t()} | {:error, term()}
  def ping(id) do
    encode_request("ping", %{}, id)
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp classify_message(%{"id" => id, "result" => result} = msg) do
    %{type: :response, id: id, result: result, raw: msg}
  end

  defp classify_message(%{"id" => id, "error" => error} = msg) do
    %{
      type: :error,
      id: id,
      error: %{
        code: error["code"],
        message: error["message"],
        data: error["data"]
      },
      raw: msg
    }
  end

  defp classify_message(%{"id" => id, "method" => method} = msg) do
    %{type: :request, id: id, method: method, params: msg["params"] || %{}, raw: msg}
  end

  defp classify_message(%{"method" => method} = msg) do
    %{type: :notification, method: method, params: msg["params"] || %{}, raw: msg}
  end

  defp classify_message(msg) do
    %{type: :unknown, raw: msg}
  end
end
