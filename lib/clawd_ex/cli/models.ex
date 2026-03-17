defmodule ClawdEx.CLI.Models do
  @moduledoc """
  CLI models command - list available AI models.

  Usage:
    clawd_ex models list
  """

  alias ClawdEx.AI.Models
  alias ClawdEx.AI.OAuth

  def run(args, opts \\ [])

  def run(["list" | _rest], opts) do
    if opts[:help] do
      print_list_help()
    else
      list_models(opts)
    end
  end

  def run(["--help" | _], _opts), do: print_help()
  def run([], _opts), do: print_help()

  def run([subcmd | _], _opts) do
    IO.puts("Unknown models subcommand: #{subcmd}\n")
    print_help()
  end

  # ---------------------------------------------------------------------------
  # models list
  # ---------------------------------------------------------------------------

  defp list_models(_opts) do
    all_models = Models.all()
    configured = configured_providers()

    # Group by provider
    grouped =
      all_models
      |> Enum.group_by(fn {_id, meta} -> meta.provider end)
      |> Enum.sort_by(fn {provider, _} -> to_string(provider) end)

    IO.puts("""
    ┌─────────────────────────────────────────────────────────────────────────────────┐
    │                             Available Models                                   │
    └─────────────────────────────────────────────────────────────────────────────────┘
    """)

    Enum.each(grouped, fn {provider, models} ->
      is_configured = provider in configured
      status = if is_configured, do: "✓ configured", else: "✗ not configured"

      IO.puts("  #{provider |> to_string() |> String.upcase()} [#{status}]")
      IO.puts("  " <> String.duplicate("─", 76))

      IO.puts(
        "  " <>
          String.pad_trailing("MODEL", 36) <>
          String.pad_trailing("ALIASES", 30) <>
          "CAPABILITIES"
      )

      models
      |> Enum.sort_by(fn {id, _} -> id end)
      |> Enum.each(fn {id, meta} ->
        aliases = (meta[:aliases] || []) |> Enum.take(3) |> Enum.join(", ")
        caps = meta.capabilities |> Enum.map(&to_string/1) |> Enum.join(", ")

        IO.puts(
          "  " <>
            String.pad_trailing(id, 36) <>
            String.pad_trailing(truncate(aliases, 28), 30) <>
            caps
        )
      end)

      IO.puts("")
    end)

    total = map_size(all_models)
    configured_count = length(configured)

    IO.puts(
      "Total: #{total} models across #{length(grouped)} providers (#{configured_count} configured)"
    )
  end

  @doc false
  def configured_providers do
    providers = []

    # Check Anthropic
    providers =
      case safe_get_api_key(:anthropic) do
        {:ok, _} -> [:anthropic | providers]
        _ -> providers
      end

    # Check OpenAI
    providers =
      case safe_get_api_key(:openai) do
        {:ok, _} -> [:openai | providers]
        _ -> providers
      end

    # Check Google/Gemini
    providers =
      case safe_get_api_key(:gemini) do
        {:ok, _} -> [:google | providers]
        _ -> providers
      end

    # Check Groq
    providers =
      case Application.get_env(:clawd_ex, :groq) do
        config when is_list(config) ->
          if config[:api_key] && config[:api_key] != "" do
            [:groq | providers]
          else
            providers
          end

        _ ->
          providers
      end

    # Check Ollama (configured if host is set)
    providers =
      case Application.get_env(:clawd_ex, :ollama) do
        config when is_list(config) ->
          if config[:host] do
            [:ollama | providers]
          else
            providers
          end

        _ ->
          providers
      end

    providers
  end

  defp safe_get_api_key(provider) do
    try do
      if Process.whereis(ClawdEx.AI.OAuth) do
        OAuth.get_api_key(provider)
      else
        {:error, :oauth_not_running}
      end
    catch
      :exit, _ -> {:error, :oauth_not_running}
    end
  end

  defp truncate(str, max) when is_binary(str) do
    if String.length(str) > max do
      String.slice(str, 0, max - 1) <> "…"
    else
      str
    end
  end

  # ---------------------------------------------------------------------------
  # Help
  # ---------------------------------------------------------------------------

  defp print_help do
    IO.puts("""
    Usage: clawd_ex models <subcommand> [options]

    Subcommands:
      list    List all available models

    Options:
      --help  Show this help message
    """)
  end

  defp print_list_help do
    IO.puts("""
    Usage: clawd_ex models list [options]

    List all available AI models grouped by provider.
    Shows which providers are configured (have API keys).

    Options:
      --help  Show this help message
    """)
  end
end
