defmodule ClawdExWeb.ModelsLive do
  @moduledoc """
  模型配置页面 - 显示 AI 提供商状态和可用模型列表
  """
  use ClawdExWeb, :live_view

  alias ClawdEx.AI.Models

  @providers [
    %{
      id: :anthropic,
      name: "Anthropic",
      icon: "🧠",
      module: nil,
      env_key: "ANTHROPIC_API_KEY",
      config_key: :anthropic_api_key
    },
    %{
      id: :openai,
      name: "OpenAI",
      icon: "🤖",
      module: nil,
      env_key: "OPENAI_API_KEY",
      config_key: :openai_api_key
    },
    %{
      id: :google,
      name: "Google",
      icon: "🔮",
      module: nil,
      env_key: "GEMINI_API_KEY",
      config_key: :gemini_api_key
    },
    %{
      id: :groq,
      name: "Groq",
      icon: "⚡",
      module: ClawdEx.AI.Providers.Groq,
      env_key: "GROQ_API_KEY",
      config_key: nil
    },
    %{
      id: :ollama,
      name: "Ollama",
      icon: "🦙",
      module: ClawdEx.AI.Providers.Ollama,
      env_key: nil,
      config_key: nil
    },
    %{
      id: :openrouter,
      name: "OpenRouter",
      icon: "🌐",
      module: ClawdEx.AI.Providers.OpenRouter,
      env_key: "OPENROUTER_API_KEY",
      config_key: nil
    }
  ]

  @impl true
  def mount(_params, _session, socket) do
    providers = load_providers()
    all_models = Models.all()

    socket =
      socket
      |> assign(:page_title, "Models")
      |> assign(:providers, providers)
      |> assign(:all_models, all_models)
      |> assign(:default_model, Models.default())
      |> assign(:default_vision, Models.default_vision())
      |> assign(:default_fast, Models.default_fast())
      |> assign(:expanded_provider, nil)

    {:ok, socket}
  end

  @impl true
  def handle_event("toggle_provider", %{"provider" => provider_id}, socket) do
    provider_atom = String.to_existing_atom(provider_id)

    expanded =
      if socket.assigns.expanded_provider == provider_atom do
        nil
      else
        provider_atom
      end

    {:noreply, assign(socket, :expanded_provider, expanded)}
  end

  @impl true
  def handle_event("set_default", %{"role" => role, "model" => model_id}, socket) do
    config_key =
      case role do
        "default" -> :default_model
        "vision" -> :default_vision_model
        "fast" -> :default_fast_model
        _ -> nil
      end

    if config_key do
      Application.put_env(:clawd_ex, config_key, model_id)

      socket =
        socket
        |> assign(:default_model, Models.default())
        |> assign(:default_vision, Models.default_vision())
        |> assign(:default_fast, Models.default_fast())
        |> put_flash(:info, "Set #{role} model to #{model_id}")

      {:noreply, socket}
    else
      {:noreply, put_flash(socket, :error, "Unknown role: #{role}")}
    end
  end

  defp load_providers do
    Enum.map(@providers, fn provider ->
      configured = check_configured(provider)

      models =
        Models.all()
        |> Enum.filter(fn {_id, meta} -> meta.provider == provider.id end)
        |> Enum.map(fn {id, meta} -> Map.put(meta, :id, id) end)
        |> Enum.sort_by(& &1.id)

      Map.merge(provider, %{
        configured: configured,
        model_count: length(models),
        models: models
      })
    end)
  end

  defp check_configured(%{module: mod}) when not is_nil(mod) do
    try do
      mod.configured?()
    rescue
      _ -> false
    end
  end

  defp check_configured(%{env_key: env_key}) when not is_nil(env_key) do
    case System.get_env(env_key) do
      nil -> false
      "" -> false
      _ -> true
    end
  end

  defp check_configured(_), do: false

  defp status_badge_class(true), do: "bg-green-500/20 text-green-400 border-green-500/30"
  defp status_badge_class(false), do: "bg-gray-500/20 text-gray-400 border-gray-500/30"

  defp status_text(true), do: "Configured"
  defp status_text(false), do: "Not Configured"

  defp capability_color(:chat), do: "bg-blue-500/20 text-blue-300"
  defp capability_color(:vision), do: "bg-purple-500/20 text-purple-300"
  defp capability_color(:tools), do: "bg-yellow-500/20 text-yellow-300"
  defp capability_color(:reasoning), do: "bg-pink-500/20 text-pink-300"
  defp capability_color(_), do: "bg-gray-500/20 text-gray-300"

  defp format_number(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp format_number(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 0) |> trunc()}K"
  defp format_number(n), do: to_string(n)

  defp is_default?(model_id, assigns) do
    model_id == assigns.default_model ||
      model_id == assigns.default_vision ||
      model_id == assigns.default_fast
  end

  defp default_label(model_id, assigns) do
    cond do
      model_id == assigns.default_model -> "Default"
      model_id == assigns.default_vision -> "Vision"
      model_id == assigns.default_fast -> "Fast"
      true -> nil
    end
  end

end
