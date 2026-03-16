defmodule ClawdEx.Security.ExecSandbox do
  @moduledoc """
  Exec 沙箱 — 包装 shell 命令在受限环境中执行。

  功能:
  - 工作目录强制限制
  - 环境变量过滤（剥离敏感变量）
  - 超时强制
  - 输出大小限制（防 OOM）
  """

  require Logger

  @max_output_bytes 1_048_576
  @max_timeout_ms 1_800_000
  @default_timeout_ms 30_000

  @sensitive_env_vars ~w(
    AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
    DATABASE_URL SECRET_KEY_BASE
    OPENAI_API_KEY ANTHROPIC_API_KEY
    GITHUB_TOKEN GH_TOKEN
    TELEGRAM_BOT_TOKEN DISCORD_BOT_TOKEN
    GOOGLE_CLIENT_SECRET
  )

  @doc """
  Wrap exec params with sandbox restrictions.

  Takes the original exec params and context, returns sanitized params
  with enforced constraints.
  """
  @spec sandbox(map(), map()) :: {:ok, map()} | {:error, term()}
  def sandbox(params, context) do
    with {:ok, params} <- enforce_workdir(params, context),
         {:ok, params} <- enforce_timeout(params),
         {:ok, params} <- filter_env(params),
         {:ok, params} <- add_output_limit(params) do
      {:ok, params}
    end
  end

  # ============================================================================
  # Working directory enforcement
  # ============================================================================

  defp enforce_workdir(params, context) do
    workspace = context[:workspace] || Application.get_env(:clawd_ex, :workspace, ".")
    allowed_dirs = context[:allowed_dirs] || [workspace]
    workdir = params["workdir"] || params[:workdir] || workspace

    resolved = Path.expand(workdir)

    if Enum.any?(allowed_dirs, fn dir -> String.starts_with?(resolved, Path.expand(dir)) end) do
      {:ok, Map.put(params, "workdir", resolved)}
    else
      Logger.warning("Workdir #{resolved} is outside allowed directories: #{inspect(allowed_dirs)}")
      {:error, {:workdir_denied, "Working directory '#{resolved}' is outside allowed paths"}}
    end
  end

  # ============================================================================
  # Timeout enforcement
  # ============================================================================

  defp enforce_timeout(params) do
    timeout_s = params["timeout"] || params[:timeout] || div(@default_timeout_ms, 1000)
    timeout_ms = timeout_s * 1000
    clamped = min(timeout_ms, @max_timeout_ms)

    {:ok, Map.put(params, "timeout", div(clamped, 1000))}
  end

  # ============================================================================
  # Environment variable filtering
  # ============================================================================

  defp filter_env(params) do
    env = params["env"] || params[:env] || %{}

    filtered =
      Map.drop(env, @sensitive_env_vars)
      |> Map.drop(Enum.map(@sensitive_env_vars, &String.downcase/1))

    {:ok, Map.put(params, "env", filtered)}
  end

  # ============================================================================
  # Output size limit
  # ============================================================================

  defp add_output_limit(params) do
    # Inject a wrapper that limits output via head -c
    command = params["command"] || params[:command] || ""

    # Wrap with output limiter using head to cap bytes
    wrapped = "(#{command}) | head -c #{@max_output_bytes}"

    {:ok, Map.put(params, "command", wrapped)}
  end

  @doc "Get the maximum output bytes limit"
  @spec max_output_bytes() :: integer()
  def max_output_bytes, do: @max_output_bytes

  @doc "Get the list of sensitive environment variable names"
  @spec sensitive_env_vars() :: [String.t()]
  def sensitive_env_vars, do: @sensitive_env_vars
end
