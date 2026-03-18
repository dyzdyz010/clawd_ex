defmodule ClawdEx.Config.HotReload do
  @moduledoc "Runtime config hot-reload without restart"

  require Logger

  @reloadable_keys [
    :default_model,
    :max_tool_iterations,
    :gateway_token,
    :exec_approval,
    :plugins
  ]

  @doc "Reload config from runtime.exs or env vars"
  def reload do
    results =
      Enum.map(@reloadable_keys, fn key ->
        {key, reload_key(key)}
      end)

    Logger.info("[HotReload] Config reloaded: #{inspect(Enum.map(results, &elem(&1, 0)))}")
    {:ok, results}
  end

  @doc "Update a single config key at runtime"
  def put(key, value) when key in @reloadable_keys do
    Application.put_env(:clawd_ex, key, value)
    Logger.info("[HotReload] Config updated: #{key}")
    :ok
  end

  def put(key, _value) do
    {:error, "Key #{inspect(key)} is not hot-reloadable"}
  end

  @doc "Get current value of a config key"
  def get(key) do
    Application.get_env(:clawd_ex, key)
  end

  @doc "List all reloadable keys with current values"
  def list do
    Enum.map(@reloadable_keys, fn key ->
      {key, Application.get_env(:clawd_ex, key)}
    end)
  end

  @doc "Return the list of reloadable keys"
  def reloadable_keys, do: @reloadable_keys

  defp reload_key(key) do
    case env_for_key(key) do
      nil ->
        :unchanged

      env_val ->
        Application.put_env(:clawd_ex, key, env_val)
        :updated
    end
  end

  defp env_for_key(:default_model), do: System.get_env("CLAWD_DEFAULT_MODEL")

  defp env_for_key(:max_tool_iterations) do
    case System.get_env("CLAWD_MAX_TOOL_ITERATIONS") do
      nil -> nil
      val -> String.to_integer(val)
    end
  end

  defp env_for_key(:gateway_token), do: System.get_env("CLAWD_GATEWAY_TOKEN")

  defp env_for_key(:exec_approval) do
    case System.get_env("CLAWD_EXEC_APPROVAL") do
      "false" -> false
      "true" -> true
      _ -> nil
    end
  end

  defp env_for_key(_), do: nil
end
