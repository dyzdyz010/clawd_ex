defmodule ClawdEx.AI.Models do
  @moduledoc """
  中心化模型配置管理

  提供:
  - 默认模型配置
  - 模型别名解析
  - 模型元数据（能力、上下文窗口等）
  - 提供商检测
  """

  # ============================================================================
  # 模型定义
  # ============================================================================

  @models %{
    # Anthropic Claude
    "anthropic/claude-sonnet-4-20250514" => %{
      provider: :anthropic,
      capabilities: [:chat, :vision, :tools],
      context_window: 200_000,
      aliases: ["sonnet", "claude-sonnet", "claude-sonnet-4"]
    },
    "anthropic/claude-opus-4-20250514" => %{
      provider: :anthropic,
      capabilities: [:chat, :vision, :tools],
      context_window: 200_000,
      aliases: ["opus", "claude-opus", "claude-opus-4"]
    },
    "anthropic/claude-3-5-sonnet-20241022" => %{
      provider: :anthropic,
      capabilities: [:chat, :vision, :tools],
      context_window: 200_000,
      aliases: ["sonnet-3.5", "claude-3-sonnet"]
    },
    "anthropic/claude-3-5-haiku-20241022" => %{
      provider: :anthropic,
      capabilities: [:chat, :vision, :tools],
      context_window: 200_000,
      aliases: ["haiku", "claude-haiku", "claude-3-haiku"]
    },

    # OpenAI GPT
    "openai/gpt-4o" => %{
      provider: :openai,
      capabilities: [:chat, :vision, :tools],
      context_window: 128_000,
      aliases: ["gpt4o", "4o"]
    },
    "openai/gpt-4o-mini" => %{
      provider: :openai,
      capabilities: [:chat, :vision, :tools],
      context_window: 128_000,
      aliases: ["gpt4o-mini", "4o-mini", "mini"]
    },
    "openai/gpt-4-turbo" => %{
      provider: :openai,
      capabilities: [:chat, :vision, :tools],
      context_window: 128_000,
      aliases: ["gpt4-turbo", "gpt4t"]
    },
    "openai/o1" => %{
      provider: :openai,
      capabilities: [:chat, :reasoning],
      context_window: 200_000,
      aliases: ["o1"]
    },
    "openai/o1-mini" => %{
      provider: :openai,
      capabilities: [:chat, :reasoning],
      context_window: 128_000,
      aliases: ["o1-mini"]
    },

    # Google Gemini
    "google/gemini-2.0-flash" => %{
      provider: :google,
      capabilities: [:chat, :vision, :tools],
      context_window: 1_000_000,
      aliases: ["gemini", "gemini-flash", "flash"]
    },
    "google/gemini-1.5-pro" => %{
      provider: :google,
      capabilities: [:chat, :vision, :tools],
      context_window: 2_000_000,
      aliases: ["gemini-pro", "gemini-1.5"]
    }
  }

  # 默认配置键
  @default_model_key "anthropic/claude-sonnet-4-20250514"
  @default_vision_model_key "anthropic/claude-sonnet-4-20250514"
  @default_fast_model_key "anthropic/claude-3-5-haiku-20241022"

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  获取默认聊天模型
  """
  @spec default :: String.t()
  def default do
    Application.get_env(:clawd_ex, :default_model, @default_model_key)
  end

  @doc """
  获取默认视觉模型
  """
  @spec default_vision :: String.t()
  def default_vision do
    Application.get_env(:clawd_ex, :default_vision_model, @default_vision_model_key)
  end

  @doc """
  获取默认快速模型（用于简单任务）
  """
  @spec default_fast :: String.t()
  def default_fast do
    Application.get_env(:clawd_ex, :default_fast_model, @default_fast_model_key)
  end

  @doc """
  获取所有已知模型
  """
  @spec all :: map()
  def all, do: @models

  @doc """
  获取模型元数据
  """
  @spec get(String.t()) :: map() | nil
  def get(model_id) do
    Map.get(@models, model_id)
  end

  @doc """
  解析模型名（支持别名）

  ## Examples

      iex> Models.resolve("sonnet")
      "anthropic/claude-sonnet-4-20250514"

      iex> Models.resolve("openai/gpt-4o")
      "openai/gpt-4o"

      iex> Models.resolve("unknown")
      "unknown"
  """
  @spec resolve(String.t() | nil) :: String.t()
  def resolve(nil), do: default()
  def resolve(""), do: default()

  def resolve(model_or_alias) do
    # 先检查是否是完整模型名
    if Map.has_key?(@models, model_or_alias) do
      model_or_alias
    else
      # 尝试别名解析
      find_by_alias(model_or_alias) || model_or_alias
    end
  end

  @doc """
  解析提供商和模型名

  ## Examples

      iex> Models.parse("anthropic/claude-sonnet-4-20250514")
      {:anthropic, "claude-sonnet-4-20250514"}

      iex> Models.parse("sonnet")
      {:anthropic, "claude-sonnet-4-20250514"}
  """
  @spec parse(String.t()) :: {atom(), String.t()}
  def parse(model_or_alias) do
    full_model = resolve(model_or_alias)

    case String.split(full_model, "/", parts: 2) do
      ["anthropic", name] -> {:anthropic, name}
      ["openai", name] -> {:openai, name}
      ["google", name] -> {:google, name}
      ["openrouter", name] -> {:openrouter, "openrouter/" <> name}
      [name] -> {:anthropic, name}
      _ -> {:unknown, full_model}
    end
  end

  @doc """
  获取模型的提供商
  """
  @spec provider(String.t()) :: atom()
  def provider(model_or_alias) do
    {provider, _} = parse(model_or_alias)
    provider
  end

  @doc """
  检查模型是否支持某项能力
  """
  @spec has_capability?(String.t(), atom()) :: boolean()
  def has_capability?(model_or_alias, capability) do
    full_model = resolve(model_or_alias)

    case get(full_model) do
      %{capabilities: caps} -> capability in caps
      nil -> false
    end
  end

  @doc """
  获取支持视觉的模型列表
  """
  @spec vision_models :: [String.t()]
  def vision_models do
    @models
    |> Enum.filter(fn {_, meta} -> :vision in meta.capabilities end)
    |> Enum.map(fn {id, _} -> id end)
  end

  @doc """
  获取支持工具调用的模型列表
  """
  @spec tool_models :: [String.t()]
  def tool_models do
    @models
    |> Enum.filter(fn {_, meta} -> :tools in meta.capabilities end)
    |> Enum.map(fn {id, _} -> id end)
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp find_by_alias(alias_name) do
    # 标准化别名（小写，去除空格）
    normalized = alias_name |> String.downcase() |> String.trim()

    Enum.find_value(@models, fn {model_id, meta} ->
      aliases = meta[:aliases] || []

      if normalized in Enum.map(aliases, &String.downcase/1) do
        model_id
      end
    end)
  end
end
