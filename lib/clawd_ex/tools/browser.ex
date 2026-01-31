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
          enum: ["status", "start", "stop", "tabs", "open", "close", "navigate", "snapshot", "screenshot", "console"],
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

  defp execute_action(action, _params) do
    {:error, "Unknown action: #{action}. Valid actions: status, start, stop, tabs, open, close, navigate, snapshot, screenshot, console"}
  end

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
