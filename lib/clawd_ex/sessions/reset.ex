defmodule ClawdEx.Sessions.Reset do
  @moduledoc """
  Session Reset 策略

  支持的重置模式:
  - :daily - 每天指定时间重置 (默认 4:00 AM)
  - :idle - 空闲超时后重置
  - :manual - 仅手动重置 (/new, /reset)

  配置示例:
  ```
  config :clawd_ex, :session_reset,
    mode: :daily,
    at_hour: 4,
    idle_minutes: 120  # 可选，与 daily 组合时先到先重置
  ```
  """

  alias ClawdEx.Sessions.Session
  alias ClawdEx.Repo

  require Logger

  @default_config %{
    mode: :daily,
    at_hour: 4,
    idle_minutes: nil
  }

  @doc """
  检查会话是否应该重置

  返回:
  - {:ok, :fresh} - 会话有效
  - {:reset, reason} - 会话应该重置
  """
  @spec should_reset?(Session.t()) :: {:ok, :fresh} | {:reset, atom()}
  def should_reset?(session) do
    config = get_config()

    cond do
      # 检查 daily reset
      config.mode == :daily && daily_expired?(session, config.at_hour) ->
        {:reset, :daily_reset}

      # 检查 idle timeout
      config.idle_minutes && idle_expired?(session, config.idle_minutes) ->
        {:reset, :idle_timeout}

      true ->
        {:ok, :fresh}
    end
  end

  @doc """
  检查消息是否是重置触发器
  """
  @spec is_reset_trigger?(String.t()) :: boolean()
  def is_reset_trigger?(message) do
    triggers = get_reset_triggers()
    trimmed = String.trim(message)

    Enum.any?(triggers, fn trigger ->
      String.starts_with?(String.downcase(trimmed), String.downcase(trigger))
    end)
  end

  @doc """
  提取重置命令后的剩余内容
  """
  @spec extract_post_reset_content(String.t()) :: String.t() | nil
  def extract_post_reset_content(message) do
    triggers = get_reset_triggers()
    trimmed = String.trim(message)

    Enum.find_value(triggers, fn trigger ->
      if String.starts_with?(String.downcase(trimmed), String.downcase(trigger)) do
        remainder = String.slice(trimmed, String.length(trigger)..-1//1) |> String.trim()
        if remainder == "", do: nil, else: remainder
      end
    end)
  end

  @doc """
  重置会话 - 清空消息并重置状态，保留 session_key
  """
  @spec reset_session!(Session.t()) :: Session.t()
  def reset_session!(session) do
    Logger.info("Resetting session: #{session.session_key}")

    import Ecto.Query

    # 删除该会话的所有消息
    from(m in ClawdEx.Sessions.Message, where: m.session_id == ^session.id)
    |> Repo.delete_all()

    # 重置会话状态和计数器
    session
    |> Session.changeset(%{
      state: :active,
      token_count: 0,
      message_count: 0,
      last_activity_at: DateTime.utc_now()
    })
    |> Repo.update!()
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp get_config do
    app_config = Application.get_env(:clawd_ex, :session_reset, [])

    %{
      mode: Keyword.get(app_config, :mode, @default_config.mode),
      at_hour: Keyword.get(app_config, :at_hour, @default_config.at_hour),
      idle_minutes: Keyword.get(app_config, :idle_minutes, @default_config.idle_minutes)
    }
  end

  defp get_reset_triggers do
    Application.get_env(:clawd_ex, :reset_triggers, ["/new", "/reset"])
  end

  defp daily_expired?(session, at_hour) do
    now = DateTime.utc_now()
    last_activity = session.last_activity_at || session.updated_at

    # 计算今天的重置时间点
    today_reset = %DateTime{
      year: now.year,
      month: now.month,
      day: now.day,
      hour: at_hour,
      minute: 0,
      second: 0,
      microsecond: {0, 0},
      time_zone: "Etc/UTC",
      zone_abbr: "UTC",
      utc_offset: 0,
      std_offset: 0
    }

    # 如果当前时间在重置时间之后，检查 last_activity 是否在重置时间之前
    if DateTime.compare(now, today_reset) == :gt do
      DateTime.compare(last_activity, today_reset) == :lt
    else
      # 当前时间在重置时间之前，检查昨天的重置时间
      yesterday_reset = DateTime.add(today_reset, -86400, :second)
      DateTime.compare(last_activity, yesterday_reset) == :lt
    end
  end

  defp idle_expired?(session, idle_minutes) do
    last_activity = session.last_activity_at || session.updated_at
    idle_threshold = DateTime.add(DateTime.utc_now(), -idle_minutes * 60, :second)

    DateTime.compare(last_activity, idle_threshold) == :lt
  end
end
