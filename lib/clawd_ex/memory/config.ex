defmodule ClawdEx.Memory.Config do
  @moduledoc """
  记忆系统配置

  从多个来源读取配置，优先级：
  1. 环境变量
  2. Application config
  3. ~/.clawd/config.json
  4. 默认值
  """

  @default_workspace "~/.clawd/workspace"
  @default_memos_url "https://memos.memtensor.cn/api/openmem/v1"

  @doc """
  获取全局默认记忆配置
  """
  @spec default() :: map()
  def default do
    file_config = read_config_file()

    %{
      backend: get_default_backend(file_config),
      config: get_backend_config(file_config)
    }
  end

  @doc """
  获取指定 Agent 的记忆配置
  """
  @spec for_agent(term()) :: map()
  def for_agent(agent_id) do
    # Agent 特定配置
    agent_config =
      Application.get_env(:clawd_ex, :agents, %{})
      |> Map.get(agent_id, %{})
      |> Map.get(:memory, %{})

    # 合并默认配置
    Map.merge(default(), agent_config)
  end

  @doc """
  获取 MemOS 配置
  """
  @spec memos() :: map()
  def memos do
    file_config = read_config_file()
    memos_config = file_config["memos"] || %{}

    %{
      api_key: System.get_env("MEMOS_API_KEY") || memos_config["api_key"],
      user_id: System.get_env("MEMOS_USER_ID") || memos_config["user_id"] || "default",
      base_url: memos_config["base_url"] || @default_memos_url
    }
  end

  @doc """
  获取 LocalFile 配置
  """
  @spec local_file() :: map()
  def local_file do
    file_config = read_config_file()

    workspace =
      System.get_env("CLAWD_WORKSPACE") ||
        Application.get_env(:clawd_ex, :workspace) ||
        file_config["workspace"] ||
        @default_workspace

    %{
      workspace: Path.expand(workspace)
    }
  end

  @doc """
  获取 PgVector 配置
  """
  @spec pgvector() :: map()
  def pgvector do
    %{
      repo: ClawdEx.Repo
    }
  end

  @doc """
  检查 MemOS 是否已配置
  """
  @spec memos_configured?() :: boolean()
  def memos_configured? do
    config = memos()
    config.api_key != nil and config.api_key != ""
  end

  # ===========================================================================
  # Private
  # ===========================================================================

  defp read_config_file do
    config_path = Path.expand("~/.clawd/config.json")

    case File.read(config_path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, config} -> config
          {:error, _} -> %{}
        end

      {:error, _} ->
        %{}
    end
  end

  defp get_default_backend(_file_config) do
    cond do
      # 如果配置了 MemOS，默认用 MemOS
      memos_configured?() -> :memos
      # 否则用本地文件
      true -> :local_file
    end
  end

  defp get_backend_config(_file_config) do
    cond do
      memos_configured?() -> memos()
      true -> local_file()
    end
  end
end
