defmodule ClawdEx.Tools.Browser do
  @moduledoc """
  浏览器控制工具

  通过 Chrome DevTools Protocol 控制浏览器。

  支持的 actions:
  - status - 获取浏览器状态
  - start - 启动浏览器
  - stop - 停止浏览器
  - tabs - 列出标签页
  - open - 打开新标签页
  - close - 关闭标签页
  - navigate - 导航到 URL
  """

  @behaviour ClawdEx.Tools.Tool

  require Logger

  alias ClawdEx.Browser.Server

  @impl true
  def name, do: "browser"

  @impl true
  def description do
    """
    Control a browser via Chrome DevTools Protocol.
    Actions: status, start, stop, tabs, open, close, navigate.
    Use this for web automation, screenshots, and browser-based tasks.
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
            "status", "start", "stop", "tabs", "open", "close", "navigate",
            "snapshot", "screenshot", "console", "act", "evaluate", "upload", "dialog"
          ],
          description: "Action to perform"
        },
        url: %{
          type: "string",
          description: "URL for 'open' or 'navigate' actions"
        },
        targetId: %{
          type: "string",
          description: "Tab/target ID for actions that operate on a specific tab"
        },
        ref: %{
          type: "string",
          description: "Element reference from snapshot (e.g., 'e12', CSS selector, or role:name)"
        },
        headless: %{
          type: "boolean",
          description: "Run browser in headless mode (default: true)"
        },
        snapshotFormat: %{
          type: "string",
          enum: ["aria", "ai"],
          description: "Snapshot format: 'aria' for accessibility tree, 'ai' for AI description"
        },
        fullPage: %{
          type: "boolean",
          description: "Take full page screenshot (default: false)"
        },
        type: %{
          type: "string",
          enum: ["png", "jpeg"],
          description: "Screenshot format (default: png)"
        },
        quality: %{
          type: "integer",
          description: "Screenshot quality for JPEG (0-100)"
        },
        level: %{
          type: "string",
          enum: ["error", "warning", "log", "info", "debug"],
          description: "Console log level filter"
        },
        limit: %{
          type: "integer",
          description: "Maximum number of console entries to return"
        },
        request: %{
          type: "object",
          description: "Action request for 'act' action",
          properties: %{
            kind: %{
              type: "string",
              enum: ["click", "type", "press", "hover", "select", "fill", "drag", "wait"],
              description: "Interaction type"
            },
            ref: %{
              type: "string",
              description: "Element reference"
            },
            text: %{
              type: "string",
              description: "Text to type or fill"
            },
            key: %{
              type: "string",
              description: "Key to press (e.g., 'Enter', 'Tab', 'Escape')"
            },
            modifiers: %{
              type: "array",
              items: %{type: "string"},
              description: "Key modifiers (e.g., ['Shift', 'Control'])"
            },
            values: %{
              type: "array",
              items: %{type: "string"},
              description: "Select option values"
            },
            fields: %{
              type: "array",
              items: %{type: "object"},
              description: "Form fields for fill action [{ref, text}, ...]"
            },
            doubleClick: %{
              type: "boolean",
              description: "Double-click instead of single click"
            },
            button: %{
              type: "string",
              enum: ["left", "right", "middle"],
              description: "Mouse button for click"
            },
            submit: %{
              type: "boolean",
              description: "Submit form after fill (press Enter)"
            },
            slowly: %{
              type: "boolean",
              description: "Type slowly (character by character)"
            },
            startRef: %{
              type: "string",
              description: "Start element for drag"
            },
            endRef: %{
              type: "string",
              description: "End element for drag"
            },
            timeMs: %{
              type: "integer",
              description: "Time to wait in milliseconds"
            }
          }
        },
        javaScript: %{
          type: "string",
          description: "JavaScript code to evaluate"
        },
        paths: %{
          type: "array",
          items: %{type: "string"},
          description: "File paths for upload"
        },
        accept: %{
          type: "boolean",
          description: "Accept (true) or dismiss (false) dialog"
        },
        promptText: %{
          type: "string",
          description: "Text to enter in prompt dialog"
        }
      },
      required: ["action"]
    }
  end

  @impl true
  def execute(params, _context) do
    action = params["action"] || params[:action]
    execute_action(action, params)
  end

  # ============================================================================
  # Actions
  # ============================================================================

  defp execute_action("status", _params) do
    status = Server.status()
    {:ok, status}
  end

  defp execute_action("start", params) do
    headless = get_boolean(params, "headless", true)

    case Server.start_browser(headless: headless) do
      {:ok, result} ->
        {:ok, result}

      {:error, {:already_running, _status}} ->
        {:ok, %{status: "already_running", message: "Browser is already running"}}

      {:error, :chrome_not_found} ->
        {:error, "Chrome/Chromium not found. Please install Chrome or Chromium."}

      {:error, reason} ->
        {:error, "Failed to start browser: #{inspect(reason)}"}
    end
  end

  defp execute_action("stop", _params) do
    case Server.stop_browser() do
      :ok ->
        {:ok, %{status: "stopped", message: "Browser stopped successfully"}}

      {:error, :not_running} ->
        {:ok, %{status: "not_running", message: "Browser is not running"}}

      {:error, reason} ->
        {:error, "Failed to stop browser: #{inspect(reason)}"}
    end
  end

  defp execute_action("tabs", _params) do
    case Server.list_tabs() do
      {:ok, tabs} ->
        {:ok, %{tabs: tabs, count: length(tabs)}}

      {:error, :not_running} ->
        {:error, "Browser is not running. Use action: 'start' first."}

      {:error, reason} ->
        {:error, "Failed to list tabs: #{inspect(reason)}"}
    end
  end

  defp execute_action("open", params) do
    url = params["url"] || params[:url] || "about:blank"

    case Server.open_tab(url) do
      {:ok, result} ->
        {:ok, Map.merge(result, %{status: "opened", message: "New tab opened"})}

      {:error, :not_running} ->
        {:error, "Browser is not running. Use action: 'start' first."}

      {:error, reason} ->
        {:error, "Failed to open tab: #{inspect(reason)}"}
    end
  end

  defp execute_action("close", params) do
    target_id = params["targetId"] || params[:targetId]

    if target_id == nil do
      {:error, "Missing required parameter: targetId"}
    else
      case Server.close_tab(target_id) do
        :ok ->
          {:ok, %{status: "closed", targetId: target_id, message: "Tab closed"}}

        {:error, :not_running} ->
          {:error, "Browser is not running. Use action: 'start' first."}

        {:error, :close_failed} ->
          {:error, "Failed to close tab. The tab may not exist."}

        {:error, reason} ->
          {:error, "Failed to close tab: #{inspect(reason)}"}
      end
    end
  end

  defp execute_action("navigate", params) do
    target_id = params["targetId"] || params[:targetId]
    url = params["url"] || params[:url]

    cond do
      target_id == nil ->
        {:error, "Missing required parameter: targetId"}

      url == nil ->
        {:error, "Missing required parameter: url"}

      true ->
        case Server.navigate(target_id, url) do
          {:ok, result} ->
            {:ok, Map.merge(result, %{status: "navigated", url: url})}

          {:error, :not_running} ->
            {:error, "Browser is not running. Use action: 'start' first."}

          {:error, reason} ->
            {:error, "Failed to navigate: #{inspect(reason)}"}
        end
    end
  end

  defp execute_action("snapshot", params) do
    target_id = params["targetId"] || params[:targetId]
    format = params["snapshotFormat"] || params[:snapshotFormat] || "aria"

    if target_id == nil do
      {:error, "Missing required parameter: targetId"}
    else
      case Server.snapshot(target_id, format) do
        {:ok, result} ->
          {:ok, Map.merge(result, %{status: "captured", format: format})}

        {:error, :not_running} ->
          {:error, "Browser is not running. Use action: 'start' first."}

        {:error, reason} ->
          {:error, "Failed to capture snapshot: #{inspect(reason)}"}
      end
    end
  end

  defp execute_action("screenshot", params) do
    target_id = params["targetId"] || params[:targetId]
    full_page = get_boolean(params, "fullPage", false)
    format = params["type"] || params[:type] || "png"
    quality = params["quality"] || params[:quality]

    if target_id == nil do
      {:error, "Missing required parameter: targetId"}
    else
      opts = [
        full_page: full_page,
        format: format
      ]

      opts = if quality && format == "jpeg", do: [{:quality, quality} | opts], else: opts

      case Server.screenshot(target_id, opts) do
        {:ok, result} ->
          {:ok, Map.merge(result, %{status: "captured"})}

        {:error, :not_running} ->
          {:error, "Browser is not running. Use action: 'start' first."}

        {:error, reason} ->
          {:error, "Failed to take screenshot: #{inspect(reason)}"}
      end
    end
  end

  defp execute_action("console", params) do
    target_id = params["targetId"] || params[:targetId]
    level = params["level"] || params[:level]
    limit = params["limit"] || params[:limit] || 100

    if target_id == nil do
      {:error, "Missing required parameter: targetId"}
    else
      case Server.console_logs(target_id, level: level, limit: limit) do
        {:ok, result} ->
          {:ok, result}

        {:error, :not_running} ->
          {:error, "Browser is not running. Use action: 'start' first."}

        {:error, reason} ->
          {:error, "Failed to get console logs: #{inspect(reason)}"}
      end
    end
  end

  defp execute_action("act", params) do
    target_id = params["targetId"] || params[:targetId]
    request = params["request"] || params[:request]

    cond do
      target_id == nil ->
        {:error, "Missing required parameter: targetId"}

      request == nil ->
        {:error, "Missing required parameter: request"}

      true ->
        # 如果 ref 在顶层，合并到 request 中
        request = merge_ref_to_request(request, params)

        case validate_act_request(request) do
          :ok ->
            case Server.act(target_id, request) do
              {:ok, result} ->
                {:ok, Map.merge(result, %{status: "completed"})}

              {:error, :not_running} ->
                {:error, "Browser is not running. Use action: 'start' first."}

              {:error, reason} ->
                {:error, "Failed to execute action: #{inspect(reason)}"}
            end

          {:error, msg} ->
            {:error, msg}
        end
    end
  end

  defp execute_action("evaluate", params) do
    target_id = params["targetId"] || params[:targetId]
    js = params["javaScript"] || params[:javaScript]

    cond do
      target_id == nil ->
        {:error, "Missing required parameter: targetId"}

      js == nil ->
        {:error, "Missing required parameter: javaScript"}

      true ->
        case Server.evaluate(target_id, js) do
          {:ok, result} ->
            {:ok, %{status: "evaluated", result: result}}

          {:error, :not_running} ->
            {:error, "Browser is not running. Use action: 'start' first."}

          {:error, {:js_error, details}} ->
            {:error, "JavaScript error: #{inspect(details)}"}

          {:error, reason} ->
            {:error, "Failed to evaluate JavaScript: #{inspect(reason)}"}
        end
    end
  end

  defp execute_action("upload", params) do
    target_id = params["targetId"] || params[:targetId]
    ref = params["ref"] || params[:ref]
    paths = params["paths"] || params[:paths]

    cond do
      target_id == nil ->
        {:error, "Missing required parameter: targetId"}

      ref == nil ->
        {:error, "Missing required parameter: ref (file input element reference)"}

      paths == nil or paths == [] ->
        {:error, "Missing required parameter: paths (file paths to upload)"}

      true ->
        # 验证文件存在
        case validate_file_paths(paths) do
          :ok ->
            case Server.upload(target_id, ref, paths) do
              {:ok, result} ->
                {:ok, Map.merge(result, %{status: "uploaded"})}

              {:error, :not_running} ->
                {:error, "Browser is not running. Use action: 'start' first."}

              {:error, reason} ->
                {:error, "Failed to upload files: #{inspect(reason)}"}
            end

          {:error, msg} ->
            {:error, msg}
        end
    end
  end

  defp execute_action("dialog", params) do
    target_id = params["targetId"] || params[:targetId]
    accept = params["accept"]
    prompt_text = params["promptText"] || params[:promptText]

    # 默认为 accept
    accept = if is_nil(accept), do: true, else: accept

    if target_id == nil do
      {:error, "Missing required parameter: targetId"}
    else
      case Server.dialog(target_id, accept, prompt_text) do
        {:ok, result} ->
          {:ok, Map.merge(result, %{status: "handled"})}

        {:error, :not_running} ->
          {:error, "Browser is not running. Use action: 'start' first."}

        {:error, reason} ->
          {:error, "Failed to handle dialog: #{inspect(reason)}"}
      end
    end
  end

  defp execute_action(action, _params) do
    {:error, "Unknown action: #{action}. Valid actions: status, start, stop, tabs, open, close, navigate, snapshot, screenshot, console, act, evaluate, upload, dialog"}
  end

  # ============================================================================
  # Validation Helpers
  # ============================================================================

  defp merge_ref_to_request(request, params) when is_map(request) do
    top_ref = params["ref"] || params[:ref]
    request_ref = request["ref"] || request[:ref]

    if top_ref && is_nil(request_ref) do
      Map.put(request, "ref", top_ref)
    else
      request
    end
  end

  defp merge_ref_to_request(request, _params), do: request

  defp validate_act_request(request) when is_map(request) do
    kind = request["kind"] || request[:kind]

    case kind do
      nil ->
        {:error, "Missing required field: request.kind"}

      "click" ->
        validate_has_ref(request)

      "type" ->
        with :ok <- validate_has_ref(request),
             :ok <- validate_has_text(request) do
          :ok
        end

      "press" ->
        validate_has_key(request)

      "hover" ->
        validate_has_ref(request)

      "select" ->
        with :ok <- validate_has_ref(request),
             :ok <- validate_has_values(request) do
          :ok
        end

      "fill" ->
        validate_has_fields(request)

      "drag" ->
        with :ok <- validate_has_start_ref(request),
             :ok <- validate_has_end_ref(request) do
          :ok
        end

      "wait" ->
        :ok

      other ->
        {:error, "Unknown action kind: #{other}"}
    end
  end

  defp validate_act_request(_), do: {:error, "request must be an object"}

  defp validate_has_ref(request) do
    if request["ref"] || request[:ref] do
      :ok
    else
      {:error, "Missing required field: ref"}
    end
  end

  defp validate_has_text(request) do
    if request["text"] || request[:text] do
      :ok
    else
      {:error, "Missing required field: text"}
    end
  end

  defp validate_has_key(request) do
    if request["key"] || request[:key] do
      :ok
    else
      {:error, "Missing required field: key"}
    end
  end

  defp validate_has_values(request) do
    values = request["values"] || request[:values]

    if is_list(values) && length(values) > 0 do
      :ok
    else
      {:error, "Missing required field: values (non-empty array)"}
    end
  end

  defp validate_has_fields(request) do
    fields = request["fields"] || request[:fields]

    if is_list(fields) && length(fields) > 0 do
      :ok
    else
      {:error, "Missing required field: fields (non-empty array)"}
    end
  end

  defp validate_has_start_ref(request) do
    if request["startRef"] || request[:startRef] do
      :ok
    else
      {:error, "Missing required field: startRef"}
    end
  end

  defp validate_has_end_ref(request) do
    if request["endRef"] || request[:endRef] do
      :ok
    else
      {:error, "Missing required field: endRef"}
    end
  end

  defp validate_file_paths(paths) when is_list(paths) do
    missing =
      Enum.reject(paths, fn path ->
        File.exists?(path)
      end)

    if missing == [] do
      :ok
    else
      {:error, "Files not found: #{Enum.join(missing, ", ")}"}
    end
  end

  defp validate_file_paths(_), do: {:error, "paths must be an array of file paths"}

  # ============================================================================
  # Helpers
  # ============================================================================

  defp get_boolean(params, key, default) do
    case params[key] || params[String.to_atom(key)] do
      nil -> default
      val when is_boolean(val) -> val
      "true" -> true
      "false" -> false
      _ -> default
    end
  end
end
