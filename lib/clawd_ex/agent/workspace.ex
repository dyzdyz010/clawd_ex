defmodule ClawdEx.Agent.Workspace do
  @moduledoc """
  工作区管理器

  负责:
  - 初始化工作区目录
  - 创建默认 bootstrap 文件
  - 管理 memory 目录
  """

  require Logger

  @default_workspace "~/.clawd/workspace"

  # Bootstrap 文件列表
  @bootstrap_files [
    "AGENTS.md",
    "SOUL.md",
    "USER.md",
    "TOOLS.md",
    "IDENTITY.md",
    "MEMORY.md",
    "HEARTBEAT.md",
    "BOOTSTRAP.md"
  ]

  @doc """
  初始化工作区，创建缺失的 bootstrap 文件
  """
  @spec init(String.t() | nil) :: {:ok, String.t()} | {:error, term()}
  def init(workspace_path \\ nil) do
    workspace = resolve_workspace(workspace_path)
    expanded = Path.expand(workspace)

    Logger.info("Initializing workspace: #{expanded}")

    # 创建工作区目录
    case File.mkdir_p(expanded) do
      :ok ->
        # 创建 memory 子目录
        memory_dir = Path.join(expanded, "memory")
        File.mkdir_p(memory_dir)

        # 创建缺失的 bootstrap 文件
        create_missing_bootstrap_files(expanded)

        {:ok, expanded}

      {:error, reason} ->
        Logger.error("Failed to create workspace: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  获取工作区路径
  """
  @spec get_workspace(String.t() | nil) :: String.t()
  def get_workspace(configured_path \\ nil) do
    resolve_workspace(configured_path) |> Path.expand()
  end

  @doc """
  检查工作区是否已初始化
  """
  @spec initialized?(String.t() | nil) :: boolean()
  def initialized?(workspace_path \\ nil) do
    workspace = resolve_workspace(workspace_path) |> Path.expand()

    # 检查至少存在 AGENTS.md
    File.exists?(Path.join(workspace, "AGENTS.md"))
  end

  @doc """
  获取今日的 memory 文件路径
  """
  @spec today_memory_path(String.t() | nil) :: String.t()
  def today_memory_path(workspace_path \\ nil) do
    workspace = resolve_workspace(workspace_path) |> Path.expand()
    date = Date.utc_today() |> Date.to_iso8601()
    Path.join([workspace, "memory", "#{date}.md"])
  end

  @doc """
  确保今日的 memory 文件存在
  """
  @spec ensure_today_memory(String.t() | nil) :: :ok | {:error, term()}
  def ensure_today_memory(workspace_path \\ nil) do
    path = today_memory_path(workspace_path)
    dir = Path.dirname(path)

    with :ok <- File.mkdir_p(dir) do
      if File.exists?(path) do
        :ok
      else
        date = Date.utc_today() |> Date.to_iso8601()
        content = "# #{date}\n\n## Notes\n\n"

        case File.write(path, content) do
          :ok -> :ok
          error -> error
        end
      end
    end
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp resolve_workspace(nil) do
    Application.get_env(:clawd_ex, :workspace) ||
      System.get_env("CLAWD_WORKSPACE") ||
      @default_workspace
  end

  defp resolve_workspace(path), do: path

  defp create_missing_bootstrap_files(workspace) do
    # 获取 priv 目录中的模板
    priv_dir = :code.priv_dir(:clawd_ex)
    template_dir = Path.join(priv_dir, "bootstrap")

    Enum.each(@bootstrap_files, fn filename ->
      target_path = Path.join(workspace, filename)

      if !File.exists?(target_path) do
        # 尝试从模板复制
        template_path = Path.join(template_dir, filename)

        if File.exists?(template_path) do
          case File.copy(template_path, target_path) do
            {:ok, _} ->
              Logger.info("Created bootstrap file: #{filename}")

            {:error, reason} ->
              Logger.warning("Failed to create #{filename}: #{inspect(reason)}")
          end
        else
          # 如果没有模板，创建空文件
          File.write(target_path, "# #{filename}\n\n(No template available)\n")
          Logger.info("Created empty bootstrap file: #{filename}")
        end
      end
    end)
  end
end
