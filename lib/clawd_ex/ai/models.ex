defmodule ClawdEx.AI.Models do
  @moduledoc """
  中心化模型配置管理

  提供:
  - 默认模型配置
  - 模型别名解析
  - 模型元数据（能力、上下文窗口等）
  - 提供商检测

  模型命名遵循 OpenClaw 惯例:
  - Anthropic: claude-opus-4-5, claude-sonnet-4-5
  - OpenAI: gpt-5.2, gpt-5-mini
  - Google: gemini-3-pro, gemini-3-flash
  """

  # ============================================================================
  # 模型定义 (遵循 OpenClaw 命名规范)
  # ============================================================================

  @models %{
    # Anthropic Claude (latest models)
    "anthropic/claude-opus-4-5" => %{
      provider: :anthropic,
      api_model: "claude-opus-4-5",
      capabilities: [:chat, :vision, :tools, :reasoning],
      context_window: 200_000,
      max_tokens: 64_000,
      aliases: ["opus", "opus-4.5", "opus-4", "claude-opus"]
    },
    "anthropic/claude-sonnet-4-5" => %{
      provider: :anthropic,
      api_model: "claude-sonnet-4-5",
      capabilities: [:chat, :vision, :tools],
      context_window: 200_000,
      max_tokens: 64_000,
      aliases: ["sonnet", "sonnet-4.5", "sonnet-4", "claude-sonnet"]
    },
    "anthropic/claude-haiku-4-5" => %{
      provider: :anthropic,
      api_model: "claude-haiku-4-5",
      capabilities: [:chat, :vision, :tools],
      context_window: 200_000,
      max_tokens: 64_000,
      aliases: ["haiku", "haiku-4.5", "claude-haiku"]
    },

    # OpenAI GPT (latest models)
    "openai/gpt-5.2" => %{
      provider: :openai,
      api_model: "gpt-5.2",
      capabilities: [:chat, :vision, :tools, :reasoning],
      context_window: 400_000,
      max_tokens: 128_000,
      aliases: ["gpt", "gpt-5", "gpt5"]
    },
    "openai/gpt-5.1" => %{
      provider: :openai,
      api_model: "gpt-5.1",
      capabilities: [:chat, :vision, :tools],
      context_window: 400_000,
      max_tokens: 128_000,
      aliases: ["gpt-5.1", "gpt4"]
    },
    "openai/gpt-5-mini" => %{
      provider: :openai,
      api_model: "gpt-5-mini",
      capabilities: [:chat, :vision, :tools],
      context_window: 128_000,
      max_tokens: 16_000,
      aliases: ["gpt-mini", "mini"]
    },
    "openai/gpt-5.1-codex" => %{
      provider: :openai,
      api_model: "gpt-5.1-codex",
      capabilities: [:chat, :tools, :reasoning],
      context_window: 400_000,
      max_tokens: 128_000,
      aliases: ["codex", "gpt-codex"]
    },

    # Google Gemini (latest models)
    "google/gemini-3-pro" => %{
      provider: :google,
      api_model: "gemini-3-pro-preview",
      capabilities: [:chat, :vision, :tools],
      context_window: 1_048_576,
      max_tokens: 65_536,
      aliases: ["gemini", "gemini-pro", "gemini-3"]
    },
    "google/gemini-3-flash" => %{
      provider: :google,
      api_model: "gemini-3-flash-preview",
      capabilities: [:chat, :vision, :tools],
      context_window: 1_048_576,
      max_tokens: 65_536,
      aliases: ["flash", "gemini-flash"]
    },

    # Legacy models (for backward compatibility)
    "anthropic/claude-3-5-sonnet" => %{
      provider: :anthropic,
      api_model: "claude-3-5-sonnet-20241022",
      capabilities: [:chat, :vision, :tools],
      context_window: 200_000,
      max_tokens: 8_192,
      aliases: ["sonnet-3.5", "claude-3-sonnet"]
    },
    "openai/gpt-4o" => %{
      provider: :openai,
      api_model: "gpt-4o",
      capabilities: [:chat, :vision, :tools],
      context_window: 128_000,
      max_tokens: 16_384,
      aliases: ["gpt4o", "4o"]
    },
    "openai/gpt-4o-mini" => %{
      provider: :openai,
      api_model: "gpt-4o-mini",
      capabilities: [:chat, :vision, :tools],
      context_window: 128_000,
      max_tokens: 16_384,
      aliases: ["4o-mini"]
    }
  }

  # 默认配置键
  @default_model_key "anthropic/claude-opus-4-5"
  @default_vision_model_key "anthropic/claude-opus-4-5"
  @default_fast_model_key "anthropic/claude-haiku-4-5"

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
  获取模型的 API 模型名（发送给提供商的实际名称）
  """
  @spec api_model(String.t()) :: String.t()
  def api_model(model_id) do
    resolved = resolve(model_id)

    case get(resolved) do
      %{api_model: api_model} -> api_model
      nil -> extract_model_name(resolved)
    end
  end

  @doc """
  解析模型名（支持别名）

  ## Examples

      iex> Models.resolve("sonnet")
      "anthropic/claude-sonnet-4-5"

      iex> Models.resolve("opus")
      "anthropic/claude-opus-4-5"

      iex> Models.resolve("openai/gpt-5.2")
      "openai/gpt-5.2"
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

      iex> Models.parse("anthropic/claude-opus-4-5")
      {:anthropic, "claude-opus-4-5"}

      iex> Models.parse("sonnet")
      {:anthropic, "claude-sonnet-4-5"}
  """
  @spec parse(String.t()) :: {atom(), String.t()}
  def parse(model_or_alias) do
    full_model = resolve(model_or_alias)

    case String.split(full_model, "/", parts: 2) do
      ["anthropic", name] -> {:anthropic, api_model_for(full_model, name)}
      ["openai", name] -> {:openai, api_model_for(full_model, name)}
      ["google", name] -> {:google, api_model_for(full_model, name)}
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

  @doc """
  获取模型的上下文窗口大小
  """
  @spec context_window(String.t()) :: integer()
  def context_window(model_or_alias) do
    full_model = resolve(model_or_alias)

    case get(full_model) do
      %{context_window: cw} -> cw
      # 默认值
      nil -> 128_000
    end
  end

  @doc """
  获取模型的最大输出 token 数
  """
  @spec max_tokens(String.t()) :: integer()
  def max_tokens(model_or_alias) do
    full_model = resolve(model_or_alias)

    case get(full_model) do
      %{max_tokens: mt} -> mt
      # 默认值
      nil -> 8_192
    end
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

  defp api_model_for(full_model, default_name) do
    case get(full_model) do
      %{api_model: api_model} -> api_model
      nil -> default_name
    end
  end

  defp extract_model_name(model_ref) do
    case String.split(model_ref, "/", parts: 2) do
      [_, name] -> name
      [name] -> name
    end
  end
end
