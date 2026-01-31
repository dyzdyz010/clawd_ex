defmodule ClawdEx.Tools.Nodes do
  @moduledoc """
  节点工具 - 管理和控制已配对的远程节点

  支持的操作:
  - status: 获取所有配对节点的状态
  - describe: 获取节点详细信息
  - pending: 列出待审批的配对请求
  - approve: 批准配对请求
  - reject: 拒绝配对请求
  - notify: 发送通知到节点
  - run: 在节点上执行命令
  - camera_snap: 拍摄照片
  - camera_list: 列出可用摄像头
  - camera_clip: 录制短视频
  - screen_record: 录制屏幕
  - location_get: 获取节点位置
  """
  @behaviour ClawdEx.Tools.Tool

  require Logger

  @default_timeout 60_000

  @impl true
  def name, do: "nodes"

  @impl true
  def description do
    """
    Discover and control paired nodes (status/describe/pairing/notify/camera/screen/location/run).

    Actions:
    - status: List all paired nodes and their status
    - describe: Get detailed info about a specific node
    - pending: List pending pairing requests
    - approve: Approve a pairing request
    - reject: Reject a pairing request
    - notify: Send a notification to a node
    - run: Execute a command on a node
    - camera_snap: Take a photo from node camera
    - camera_list: List available cameras on node
    - camera_clip: Record a short video clip
    - screen_record: Record the node's screen
    - location_get: Get the node's current location
    """
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        action: %{
          type: "string",
          enum: [
            "status",
            "describe",
            "pending",
            "approve",
            "reject",
            "notify",
            "run",
            "camera_snap",
            "camera_list",
            "camera_clip",
            "screen_record",
            "location_get"
          ],
          description: "Action to perform"
        },
        node: %{
          type: "string",
          description: "Node ID or name (required for most actions except status/pending)"
        },
        # Pairing
        requestId: %{
          type: "string",
          description: "Pairing request ID (for approve/reject)"
        },
        # Notify
        title: %{
          type: "string",
          description: "Notification title"
        },
        body: %{
          type: "string",
          description: "Notification body text"
        },
        priority: %{
          type: "string",
          enum: ["passive", "active", "timeSensitive"],
          description: "Notification priority"
        },
        sound: %{
          type: "string",
          description: "Notification sound name"
        },
        delivery: %{
          type: "string",
          enum: ["system", "overlay", "auto"],
          description: "Notification delivery method"
        },
        # Run
        command: %{
          type: "array",
          items: %{type: "string"},
          description: "Command and arguments to execute"
        },
        cwd: %{
          type: "string",
          description: "Working directory for command"
        },
        env: %{
          type: "array",
          items: %{type: "string"},
          description: "Environment variables (KEY=VALUE format)"
        },
        commandTimeoutMs: %{
          type: "integer",
          description: "Command timeout in milliseconds"
        },
        # Camera
        facing: %{
          type: "string",
          enum: ["front", "back", "both"],
          description: "Camera facing direction"
        },
        deviceId: %{
          type: "string",
          description: "Specific camera device ID"
        },
        quality: %{
          type: "number",
          description: "Image/video quality (0-100)"
        },
        maxWidth: %{
          type: "integer",
          description: "Maximum image/video width"
        },
        # Video recording
        durationMs: %{
          type: "integer",
          description: "Recording duration in milliseconds"
        },
        duration: %{
          type: "string",
          description: "Recording duration string (e.g., '10s', '1m')"
        },
        fps: %{
          type: "integer",
          description: "Frames per second for video recording"
        },
        includeAudio: %{
          type: "boolean",
          description: "Include audio in recording"
        },
        # Screen recording
        screenIndex: %{
          type: "integer",
          description: "Screen index to record (for multi-monitor)"
        },
        needsScreenRecording: %{
          type: "boolean",
          description: "Whether screen recording permission is needed"
        },
        # Location
        desiredAccuracy: %{
          type: "string",
          enum: ["coarse", "balanced", "precise"],
          description: "Desired location accuracy"
        },
        maxAgeMs: %{
          type: "integer",
          description: "Maximum age of cached location in milliseconds"
        },
        locationTimeoutMs: %{
          type: "integer",
          description: "Location request timeout in milliseconds"
        },
        # Output
        outPath: %{
          type: "string",
          description: "Output file path for media"
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
          description: "Overall request timeout in milliseconds"
        },
        invokeTimeoutMs: %{
          type: "integer",
          description: "Node invoke timeout in milliseconds"
        },
        delayMs: %{
          type: "integer",
          description: "Delay before executing action"
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

    Logger.debug("[Nodes] Executing action: #{action}")

    case action do
      "status" ->
        do_status(gateway_url, gateway_token, timeout)

      "describe" ->
        do_describe(params, gateway_url, gateway_token, timeout)

      "pending" ->
        do_pending(gateway_url, gateway_token, timeout)

      "approve" ->
        do_approve(params, gateway_url, gateway_token, timeout)

      "reject" ->
        do_reject(params, gateway_url, gateway_token, timeout)

      "notify" ->
        do_notify(params, gateway_url, gateway_token, timeout)

      "run" ->
        do_run(params, gateway_url, gateway_token, timeout)

      "camera_snap" ->
        do_camera_snap(params, gateway_url, gateway_token, timeout)

      "camera_list" ->
        do_camera_list(params, gateway_url, gateway_token, timeout)

      "camera_clip" ->
        do_camera_clip(params, gateway_url, gateway_token, timeout)

      "screen_record" ->
        do_screen_record(params, gateway_url, gateway_token, timeout)

      "location_get" ->
        do_location_get(params, gateway_url, gateway_token, timeout)

      _ ->
        {:error, "Unknown action: #{action}. Use one of: status, describe, pending, approve, reject, notify, run, camera_snap, camera_list, camera_clip, screen_record, location_get"}
    end
  end

  # ============================================================================
  # Action Implementations
  # ============================================================================

  defp do_status(gateway_url, token, timeout) do
    call_gateway(gateway_url, token, "status", %{}, timeout)
  end

  defp do_describe(params, gateway_url, token, timeout) do
    node = get_param(params, :node)

    if is_nil(node) do
      {:error, "node parameter is required for describe action"}
    else
      call_gateway(gateway_url, token, "describe", %{node: node}, timeout)
    end
  end

  defp do_pending(gateway_url, token, timeout) do
    call_gateway(gateway_url, token, "pending", %{}, timeout)
  end

  defp do_approve(params, gateway_url, token, timeout) do
    request_id = get_param(params, :requestId)

    if is_nil(request_id) do
      {:error, "requestId parameter is required for approve action"}
    else
      call_gateway(gateway_url, token, "approve", %{requestId: request_id}, timeout)
    end
  end

  defp do_reject(params, gateway_url, token, timeout) do
    request_id = get_param(params, :requestId)

    if is_nil(request_id) do
      {:error, "requestId parameter is required for reject action"}
    else
      call_gateway(gateway_url, token, "reject", %{requestId: request_id}, timeout)
    end
  end

  defp do_notify(params, gateway_url, token, timeout) do
    node = get_param(params, :node)

    if is_nil(node) do
      {:error, "node parameter is required for notify action"}
    else
      body = %{
        node: node,
        title: get_param(params, :title),
        body: get_param(params, :body),
        priority: get_param(params, :priority),
        sound: get_param(params, :sound),
        delivery: get_param(params, :delivery)
      }
      |> reject_nil_values()

      call_gateway(gateway_url, token, "notify", body, timeout)
    end
  end

  defp do_run(params, gateway_url, token, timeout) do
    node = get_param(params, :node)
    command = get_param(params, :command)

    cond do
      is_nil(node) ->
        {:error, "node parameter is required for run action"}

      is_nil(command) ->
        {:error, "command parameter is required for run action"}

      true ->
        body = %{
          node: node,
          command: command,
          cwd: get_param(params, :cwd),
          env: get_param(params, :env),
          commandTimeoutMs: get_param(params, :commandTimeoutMs),
          invokeTimeoutMs: get_param(params, :invokeTimeoutMs)
        }
        |> reject_nil_values()

        call_gateway(gateway_url, token, "run", body, timeout)
    end
  end

  defp do_camera_snap(params, gateway_url, token, timeout) do
    node = get_param(params, :node)

    if is_nil(node) do
      {:error, "node parameter is required for camera_snap action"}
    else
      body = %{
        node: node,
        facing: get_param(params, :facing),
        deviceId: get_param(params, :deviceId),
        quality: get_param(params, :quality),
        maxWidth: get_param(params, :maxWidth),
        delayMs: get_param(params, :delayMs)
      }
      |> reject_nil_values()

      result = call_gateway(gateway_url, token, "camera_snap", body, timeout)
      process_media_result(result, params)
    end
  end

  defp do_camera_list(params, gateway_url, token, timeout) do
    node = get_param(params, :node)

    if is_nil(node) do
      {:error, "node parameter is required for camera_list action"}
    else
      call_gateway(gateway_url, token, "camera_list", %{node: node}, timeout)
    end
  end

  defp do_camera_clip(params, gateway_url, token, timeout) do
    node = get_param(params, :node)

    if is_nil(node) do
      {:error, "node parameter is required for camera_clip action"}
    else
      body = %{
        node: node,
        facing: get_param(params, :facing),
        deviceId: get_param(params, :deviceId),
        quality: get_param(params, :quality),
        maxWidth: get_param(params, :maxWidth),
        durationMs: get_param(params, :durationMs),
        duration: get_param(params, :duration),
        fps: get_param(params, :fps),
        includeAudio: get_param(params, :includeAudio),
        delayMs: get_param(params, :delayMs)
      }
      |> reject_nil_values()

      result = call_gateway(gateway_url, token, "camera_clip", body, timeout)
      process_media_result(result, params)
    end
  end

  defp do_screen_record(params, gateway_url, token, timeout) do
    node = get_param(params, :node)

    if is_nil(node) do
      {:error, "node parameter is required for screen_record action"}
    else
      body = %{
        node: node,
        screenIndex: get_param(params, :screenIndex),
        quality: get_param(params, :quality),
        maxWidth: get_param(params, :maxWidth),
        durationMs: get_param(params, :durationMs),
        duration: get_param(params, :duration),
        fps: get_param(params, :fps),
        includeAudio: get_param(params, :includeAudio),
        needsScreenRecording: get_param(params, :needsScreenRecording),
        delayMs: get_param(params, :delayMs)
      }
      |> reject_nil_values()

      result = call_gateway(gateway_url, token, "screen_record", body, timeout)
      process_media_result(result, params)
    end
  end

  defp do_location_get(params, gateway_url, token, timeout) do
    node = get_param(params, :node)

    if is_nil(node) do
      {:error, "node parameter is required for location_get action"}
    else
      body = %{
        node: node,
        desiredAccuracy: get_param(params, :desiredAccuracy),
        maxAgeMs: get_param(params, :maxAgeMs),
        locationTimeoutMs: get_param(params, :locationTimeoutMs)
      }
      |> reject_nil_values()

      call_gateway(gateway_url, token, "location_get", body, timeout)
    end
  end

  # ============================================================================
  # Gateway Communication
  # ============================================================================

  defp call_gateway(gateway_url, token, action, params, timeout) do
    url = "#{gateway_url}/api/nodes/#{action}"

    headers =
      [{"Content-Type", "application/json"}]
      |> maybe_add_auth(token)

    Logger.debug("[Nodes] Calling gateway: #{url}")

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
  # Media Processing
  # ============================================================================

  defp process_media_result({:ok, result}, params) when is_map(result) do
    out_path = get_param(params, :outPath)

    case result do
      %{"mediaPath" => path} when is_binary(path) ->
        handle_media_path(path, out_path, result)

      %{"media" => media_data, "mimeType" => mime_type} ->
        handle_media_data(media_data, mime_type, out_path, result)

      _ ->
        {:ok, result}
    end
  end

  defp process_media_result(result, _params), do: result

  defp handle_media_path(path, nil, result) do
    # No output path specified, return as-is
    {:ok, Map.put(result, "mediaPath", path)}
  end

  defp handle_media_path(path, out_path, result) do
    # Copy media to specified output path
    case File.cp(path, out_path) do
      :ok ->
        {:ok, Map.put(result, "mediaPath", out_path)}

      {:error, reason} ->
        Logger.warning("[Nodes] Failed to copy media to #{out_path}: #{inspect(reason)}")
        {:ok, Map.put(result, "mediaPath", path)}
    end
  end

  defp handle_media_data(media_data, mime_type, out_path, result) do
    # Decode base64 media data and save to file
    case Base.decode64(media_data) do
      {:ok, binary_data} ->
        save_path = out_path || generate_media_path(mime_type)

        case File.write(save_path, binary_data) do
          :ok ->
            {:ok, result |> Map.delete("media") |> Map.put("mediaPath", save_path)}

          {:error, reason} ->
            {:error, "Failed to save media: #{inspect(reason)}"}
        end

      :error ->
        {:error, "Failed to decode media data"}
    end
  end

  defp generate_media_path(mime_type) do
    ext = mime_type_to_extension(mime_type)
    timestamp = DateTime.utc_now() |> DateTime.to_unix()
    random = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)

    # Use temp directory
    temp_dir = System.tmp_dir!()
    Path.join(temp_dir, "clawd_node_#{timestamp}_#{random}.#{ext}")
  end

  defp mime_type_to_extension(mime_type) do
    case mime_type do
      "image/jpeg" -> "jpg"
      "image/png" -> "png"
      "image/gif" -> "gif"
      "image/webp" -> "webp"
      "video/mp4" -> "mp4"
      "video/quicktime" -> "mov"
      "video/webm" -> "webm"
      "audio/mpeg" -> "mp3"
      "audio/ogg" -> "ogg"
      _ -> "bin"
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
      Application.get_env(:clawd_ex, :nodes_gateway_url, "http://localhost:3030")
  end

  defp get_gateway_token(params, context) do
    get_param(params, :gatewayToken) ||
      context[:gateway_token] ||
      Application.get_env(:clawd_ex, :nodes_gateway_token)
  end

  defp maybe_add_auth(headers, nil), do: headers
  defp maybe_add_auth(headers, token), do: [{"Authorization", "Bearer #{token}"} | headers]

  defp reject_nil_values(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end
end
