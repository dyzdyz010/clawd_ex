defmodule ClawdEx.Tools.Canvas do
  @moduledoc """
  Canvas 工具 - 控制节点上的 Canvas 显示和 A2UI

  支持的操作:
  - present: 显示 canvas (通过 URL 或 HTML)
  - hide: 隐藏 canvas
  - navigate: 导航到新 URL
  - eval: 执行 JavaScript
  - snapshot: 截取 canvas 截图
  - a2ui_push: 推送 A2UI 内容 (JSONL)
  - a2ui_reset: 重置 A2UI
  """
  @behaviour ClawdEx.Tools.Tool

  require Logger

  @default_timeout 60_000

  @impl true
  def name, do: "canvas"

  @impl true
  def description do
    """
    Control node canvases (present/hide/navigate/eval/snapshot/A2UI).

    Actions:
    - present: Display a canvas with URL or HTML content
    - hide: Hide the canvas
    - navigate: Navigate to a new URL
    - eval: Execute JavaScript in the canvas
    - snapshot: Capture a screenshot of the canvas
    - a2ui_push: Push A2UI content (JSONL format)
    - a2ui_reset: Reset A2UI state

    Use snapshot to capture the rendered UI after presenting content.
    """
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        action: %{
          type: "string",
          enum: ["present", "hide", "navigate", "eval", "snapshot", "a2ui_push", "a2ui_reset"],
          description: "Action to perform on the canvas"
        },
        # Node target
        node: %{
          type: "string",
          description: "Node ID or name to control"
        },
        target: %{
          type: "string",
          description: "Canvas target identifier"
        },
        # Present/Navigate
        url: %{
          type: "string",
          description: "URL to display or navigate to"
        },
        # Eval
        javaScript: %{
          type: "string",
          description: "JavaScript code to execute in the canvas"
        },
        # A2UI
        jsonl: %{
          type: "string",
          description: "JSONL content to push to A2UI"
        },
        jsonlPath: %{
          type: "string",
          description: "Path to JSONL file to push to A2UI"
        },
        # Dimensions
        width: %{
          type: "integer",
          description: "Canvas width in pixels"
        },
        height: %{
          type: "integer",
          description: "Canvas height in pixels"
        },
        maxWidth: %{
          type: "integer",
          description: "Maximum canvas width"
        },
        # Position
        x: %{
          type: "number",
          description: "Canvas X position"
        },
        y: %{
          type: "number",
          description: "Canvas Y position"
        },
        # Snapshot options
        outputFormat: %{
          type: "string",
          enum: ["png", "jpg", "jpeg"],
          description: "Output image format for snapshot"
        },
        quality: %{
          type: "number",
          description: "Image quality for JPEG snapshots (0-100)"
        },
        delayMs: %{
          type: "integer",
          description: "Delay before taking snapshot (ms)"
        },
        # Gateway connection
        gatewayUrl: %{
          type: "string",
          description: "Gateway URL (defaults to config)"
        },
        gatewayToken: %{
          type: "string",
          description: "Gateway authentication token"
        },
        # Timing
        timeoutMs: %{
          type: "integer",
          description: "Request timeout in milliseconds"
        }
      },
      required: ["action"]
    }
  end

  @impl true
  def execute(params, context) do
    action = get_param(params, :action)
    gateway_url = get_gateway_url(params, context)
    gateway_token = get_gateway_token(params, context)
    timeout = get_param(params, :timeoutMs) || @default_timeout

    Logger.debug("[Canvas] Executing action: #{action}")

    case action do
      "present" ->
        do_present(params, gateway_url, gateway_token, timeout)

      "hide" ->
        do_hide(params, gateway_url, gateway_token, timeout)

      "navigate" ->
        do_navigate(params, gateway_url, gateway_token, timeout)

      "eval" ->
        do_eval(params, gateway_url, gateway_token, timeout)

      "snapshot" ->
        do_snapshot(params, gateway_url, gateway_token, timeout)

      "a2ui_push" ->
        do_a2ui_push(params, gateway_url, gateway_token, timeout)

      "a2ui_reset" ->
        do_a2ui_reset(params, gateway_url, gateway_token, timeout)

      _ ->
        {:error, "Unknown action: #{action}. Use one of: present, hide, navigate, eval, snapshot, a2ui_push, a2ui_reset"}
    end
  end

  # ============================================================================
  # Action Implementations
  # ============================================================================

  defp do_present(params, gateway_url, token, timeout) do
    url = get_param(params, :url)

    if is_nil(url) do
      {:error, "url parameter is required for present action"}
    else
      body = %{
        node: get_param(params, :node),
        target: get_param(params, :target),
        url: url,
        width: get_param(params, :width),
        height: get_param(params, :height),
        maxWidth: get_param(params, :maxWidth),
        x: get_param(params, :x),
        y: get_param(params, :y)
      }
      |> reject_nil_values()

      call_gateway(gateway_url, token, "present", body, timeout)
    end
  end

  defp do_hide(params, gateway_url, token, timeout) do
    body = %{
      node: get_param(params, :node),
      target: get_param(params, :target)
    }
    |> reject_nil_values()

    call_gateway(gateway_url, token, "hide", body, timeout)
  end

  defp do_navigate(params, gateway_url, token, timeout) do
    url = get_param(params, :url)

    if is_nil(url) do
      {:error, "url parameter is required for navigate action"}
    else
      body = %{
        node: get_param(params, :node),
        target: get_param(params, :target),
        url: url
      }
      |> reject_nil_values()

      call_gateway(gateway_url, token, "navigate", body, timeout)
    end
  end

  defp do_eval(params, gateway_url, token, timeout) do
    javascript = get_param(params, :javaScript)

    if is_nil(javascript) do
      {:error, "javaScript parameter is required for eval action"}
    else
      body = %{
        node: get_param(params, :node),
        target: get_param(params, :target),
        javaScript: javascript
      }
      |> reject_nil_values()

      call_gateway(gateway_url, token, "eval", body, timeout)
    end
  end

  defp do_snapshot(params, gateway_url, token, timeout) do
    body = %{
      node: get_param(params, :node),
      target: get_param(params, :target),
      width: get_param(params, :width),
      height: get_param(params, :height),
      maxWidth: get_param(params, :maxWidth),
      outputFormat: get_param(params, :outputFormat),
      quality: get_param(params, :quality),
      delayMs: get_param(params, :delayMs),
      x: get_param(params, :x),
      y: get_param(params, :y)
    }
    |> reject_nil_values()

    result = call_gateway(gateway_url, token, "snapshot", body, timeout)
    process_snapshot_result(result)
  end

  defp do_a2ui_push(params, gateway_url, token, timeout) do
    jsonl = get_param(params, :jsonl)
    jsonl_path = get_param(params, :jsonlPath)

    jsonl_content =
      cond do
        not is_nil(jsonl) ->
          {:ok, jsonl}

        not is_nil(jsonl_path) ->
          case File.read(jsonl_path) do
            {:ok, content} -> {:ok, content}
            {:error, reason} -> {:error, "Failed to read JSONL file: #{inspect(reason)}"}
          end

        true ->
          {:error, "jsonl or jsonlPath parameter is required for a2ui_push action"}
      end

    case jsonl_content do
      {:ok, content} ->
        body = %{
          node: get_param(params, :node),
          target: get_param(params, :target),
          jsonl: content
        }
        |> reject_nil_values()

        call_gateway(gateway_url, token, "a2ui_push", body, timeout)

      {:error, _} = error ->
        error
    end
  end

  defp do_a2ui_reset(params, gateway_url, token, timeout) do
    body = %{
      node: get_param(params, :node),
      target: get_param(params, :target)
    }
    |> reject_nil_values()

    call_gateway(gateway_url, token, "a2ui_reset", body, timeout)
  end

  # ============================================================================
  # Gateway Communication
  # ============================================================================

  defp call_gateway(gateway_url, token, action, params, timeout) do
    url = "#{gateway_url}/api/canvas/#{action}"

    headers =
      [{"Content-Type", "application/json"}]
      |> maybe_add_auth(token)

    Logger.debug("[Canvas] Calling gateway: #{url}")

    case Req.post(url,
           json: params,
           headers: headers,
           receive_timeout: timeout
         ) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        parse_gateway_response(body)

      {:ok, %{status: status, body: body}} ->
        error_msg = extract_error_message(body, status)
        {:error, error_msg}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, "Gateway connection failed: #{inspect(reason)}"}

      {:error, reason} ->
        {:error, "Gateway request failed: #{inspect(reason)}"}
    end
  end

  defp parse_gateway_response(body) when is_map(body) do
    case body do
      %{"ok" => true, "result" => result} ->
        {:ok, result}

      %{"ok" => true} = result ->
        {:ok, Map.delete(result, "ok")}

      %{"error" => error} ->
        {:error, error}

      result ->
        {:ok, result}
    end
  end

  defp parse_gateway_response(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> parse_gateway_response(decoded)
      {:error, _} -> {:ok, body}
    end
  end

  defp parse_gateway_response(body), do: {:ok, body}

  defp extract_error_message(body, status) when is_map(body) do
    cond do
      Map.has_key?(body, "error") -> body["error"]
      Map.has_key?(body, "message") -> body["message"]
      true -> "Gateway returned status #{status}"
    end
  end

  defp extract_error_message(_body, status), do: "Gateway returned status #{status}"

  # ============================================================================
  # Snapshot Processing
  # ============================================================================

  defp process_snapshot_result({:ok, result}) when is_map(result) do
    case result do
      %{"image" => image_data, "mimeType" => mime_type} ->
        handle_snapshot_data(image_data, mime_type, result)

      %{"imagePath" => path} ->
        {:ok, Map.put(result, "snapshotPath", path)}

      _ ->
        {:ok, result}
    end
  end

  defp process_snapshot_result(result), do: result

  defp handle_snapshot_data(image_data, mime_type, result) do
    case Base.decode64(image_data) do
      {:ok, binary_data} ->
        save_path = generate_snapshot_path(mime_type)

        case File.write(save_path, binary_data) do
          :ok ->
            {:ok, result |> Map.delete("image") |> Map.put("snapshotPath", save_path)}

          {:error, reason} ->
            {:error, "Failed to save snapshot: #{inspect(reason)}"}
        end

      :error ->
        {:error, "Failed to decode snapshot data"}
    end
  end

  defp generate_snapshot_path(mime_type) do
    ext = mime_type_to_extension(mime_type)
    timestamp = DateTime.utc_now() |> DateTime.to_unix()
    random = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)

    temp_dir = System.tmp_dir!()
    Path.join(temp_dir, "clawd_canvas_#{timestamp}_#{random}.#{ext}")
  end

  defp mime_type_to_extension(mime_type) do
    case mime_type do
      "image/png" -> "png"
      "image/jpeg" -> "jpg"
      "image/jpg" -> "jpg"
      "image/gif" -> "gif"
      "image/webp" -> "webp"
      _ -> "png"
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp get_param(params, key) do
    params[to_string(key)] || params[key]
  end

  defp get_gateway_url(params, context) do
    get_param(params, :gatewayUrl) ||
      context[:gateway_url] ||
      Application.get_env(:clawd_ex, :canvas_gateway_url, "http://localhost:3030")
  end

  defp get_gateway_token(params, context) do
    get_param(params, :gatewayToken) ||
      context[:gateway_token] ||
      Application.get_env(:clawd_ex, :canvas_gateway_token)
  end

  defp maybe_add_auth(headers, nil), do: headers
  defp maybe_add_auth(headers, token), do: [{"Authorization", "Bearer #{token}"} | headers]

  defp reject_nil_values(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end
end
