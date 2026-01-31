defmodule ClawdEx.Tools.Gateway do
  @moduledoc """
  Gateway 自管理工具

  提供 ClawdEx 应用的自我管理能力:
  - restart: 重启应用
  - config.get: 获取当前配置
  - config.apply: 应用新配置（完全覆盖）
  - config.patch: 部分更新配置
  """
  @behaviour ClawdEx.Tools.Tool

  require Logger

  @config_dir "priv/gateway"
  @config_file "config.json"

  # 默认配置
  @default_config %{
    "app" => %{
      "name" => "clawd_ex",
      "version" => "0.1.0"
    },
    "features" => %{
      "discord" => true,
      "telegram" => false,
      "web_api" => true
    },
    "limits" => %{
      "max_sessions" => 100,
      "session_timeout_minutes" => 60,
      "max_message_length" => 4096
    },
    "logging" => %{
      "level" => "info",
      "format" => "json"
    }
  }

  # 配置 schema
  @config_schema %{
    "type" => "object",
    "properties" => %{
      "app" => %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string"},
          "version" => %{"type" => "string"}
        }
      },
      "features" => %{
        "type" => "object",
        "properties" => %{
          "discord" => %{"type" => "boolean"},
          "telegram" => %{"type" => "boolean"},
          "web_api" => %{"type" => "boolean"}
        }
      },
      "limits" => %{
        "type" => "object",
        "properties" => %{
          "max_sessions" => %{"type" => "integer", "minimum" => 1},
          "session_timeout_minutes" => %{"type" => "integer", "minimum" => 1},
          "max_message_length" => %{"type" => "integer", "minimum" => 100}
        }
      },
      "logging" => %{
        "type" => "object",
        "properties" => %{
          "level" => %{"type" => "string", "enum" => ["debug", "info", "warning", "error"]},
          "format" => %{"type" => "string", "enum" => ["json", "text"]}
        }
      }
    }
  }

  @impl true
  def name, do: "gateway"

  @impl true
  def description do
    "Manage the ClawdEx gateway: restart, view/update configuration."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        action: %{
          type: "string",
          enum: ["restart", "config.get", "config.schema", "config.apply", "config.patch"],
          description: "Action to perform"
        },
        config: %{
          type: "object",
          description: "Configuration object (for config.apply and config.patch)"
        },
        key: %{
          type: "string",
          description: "Dot-notation key path (for config.get, e.g., 'features.discord')"
        }
      },
      required: ["action"]
    }
  end

  @impl true
  def execute(params, _context) do
    action = params["action"] || params[:action]

    case action do
      "restart" -> do_restart()
      "config.get" -> do_config_get(params)
      "config.schema" -> do_config_schema()
      "config.apply" -> do_config_apply(params)
      "config.patch" -> do_config_patch(params)
      _ -> {:error, "Unknown action: #{action}"}
    end
  end

  # ============================================================================
  # Actions
  # ============================================================================

  defp do_restart do
    Logger.info("[Gateway] Restart requested")

    # 在生产环境中，使用 Application.stop/start 或信号
    # 这里我们调度一个异步重启
    spawn(fn ->
      :timer.sleep(1000)
      Logger.info("[Gateway] Executing restart...")

      # 停止并重启应用
      Application.stop(:clawd_ex)
      :timer.sleep(500)
      Application.ensure_all_started(:clawd_ex)
    end)

    {:ok, %{
      status: "scheduled",
      message: "Restart scheduled. The application will restart in ~1 second."
    }}
  end

  defp do_config_get(params) do
    key = params["key"] || params[:key]
    config = load_config()

    result =
      if key do
        get_nested(config, String.split(key, "."))
      else
        config
      end

    case result do
      nil -> {:error, "Key not found: #{key}"}
      value -> {:ok, %{config: value}}
    end
  end

  defp do_config_schema do
    {:ok, %{schema: @config_schema}}
  end

  defp do_config_apply(params) do
    new_config = params["config"] || params[:config]

    if is_nil(new_config) do
      {:error, "config parameter is required for config.apply"}
    else
      case validate_config(new_config) do
        :ok ->
          case save_config(new_config) do
            :ok ->
              Logger.info("[Gateway] Configuration applied")
              {:ok, %{status: "applied", config: new_config}}

            {:error, reason} ->
              {:error, "Failed to save config: #{inspect(reason)}"}
          end

        {:error, reason} ->
          {:error, "Invalid configuration: #{reason}"}
      end
    end
  end

  defp do_config_patch(params) do
    patch = params["config"] || params[:config]

    if is_nil(patch) do
      {:error, "config parameter is required for config.patch"}
    else
      current_config = load_config()
      new_config = deep_merge(current_config, patch)

      case validate_config(new_config) do
        :ok ->
          case save_config(new_config) do
            :ok ->
              Logger.info("[Gateway] Configuration patched")
              {:ok, %{status: "patched", config: new_config}}

            {:error, reason} ->
              {:error, "Failed to save config: #{inspect(reason)}"}
          end

        {:error, reason} ->
          {:error, "Invalid configuration: #{reason}"}
      end
    end
  end

  # ============================================================================
  # Config File Operations
  # ============================================================================

  defp config_path do
    Path.join([Application.app_dir(:clawd_ex), @config_dir, @config_file])
  end

  defp ensure_config_dir do
    dir = Path.join(Application.app_dir(:clawd_ex), @config_dir)

    unless File.exists?(dir) do
      File.mkdir_p!(dir)
    end

    dir
  end

  defp load_config do
    path = config_path()

    if File.exists?(path) do
      case File.read(path) do
        {:ok, content} ->
          case Jason.decode(content) do
            {:ok, config} -> config
            {:error, _} -> @default_config
          end

        {:error, _} ->
          @default_config
      end
    else
      # 首次运行，创建默认配置
      ensure_config_dir()
      save_config(@default_config)
      @default_config
    end
  end

  defp save_config(config) do
    ensure_config_dir()
    path = config_path()

    case Jason.encode(config, pretty: true) do
      {:ok, json} ->
        File.write(path, json)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp get_nested(map, []), do: map
  defp get_nested(nil, _), do: nil
  defp get_nested(map, [key | rest]) when is_map(map) do
    get_nested(Map.get(map, key), rest)
  end
  defp get_nested(_, _), do: nil

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn
      _key, left_val, right_val when is_map(left_val) and is_map(right_val) ->
        deep_merge(left_val, right_val)

      _key, _left_val, right_val ->
        right_val
    end)
  end

  defp deep_merge(_left, right), do: right

  defp validate_config(config) when is_map(config) do
    # 基本验证：确保是有效的 map
    # 在生产环境中可以使用 JSON Schema 验证库
    cond do
      not is_map(config) ->
        {:error, "Config must be an object"}

      has_invalid_types?(config) ->
        {:error, "Config contains invalid types"}

      true ->
        :ok
    end
  end

  defp validate_config(_), do: {:error, "Config must be an object"}

  defp has_invalid_types?(config) when is_map(config) do
    Enum.any?(config, fn {_k, v} ->
      case v do
        v when is_map(v) -> has_invalid_types?(v)
        v when is_list(v) -> Enum.any?(v, &has_invalid_types?/1)
        v when is_binary(v) -> false
        v when is_number(v) -> false
        v when is_boolean(v) -> false
        nil -> false
        _ -> true
      end
    end)
  end

  defp has_invalid_types?(_), do: false
end
