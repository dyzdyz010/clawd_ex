defmodule ClawdEx.CLI.Memory do
  @moduledoc """
  CLI memory command - search agent memory.

  Usage:
    clawd_ex memory search <query>
  """

  alias ClawdEx.Memory

  def run(args, opts \\ [])

  def run(["search" | rest], opts) do
    if opts[:help] do
      print_search_help()
    else
      query = Enum.join(rest, " ")

      if query == "" do
        IO.puts("Error: search query is required.\n")
        print_search_help()
      else
        search_memory(query, opts)
      end
    end
  end

  def run(["--help" | _], _opts), do: print_help()
  def run([], _opts), do: print_help()

  def run([subcmd | _], _opts) do
    IO.puts("Unknown memory subcommand: #{subcmd}\n")
    print_help()
  end

  # ---------------------------------------------------------------------------
  # memory search
  # ---------------------------------------------------------------------------

  defp search_memory(query, opts) do
    limit = opts[:limit] || 10

    # Try to get the default agent memory; fall back to local_file backend
    memory_result =
      case Memory.for_agent(:default) do
        {:ok, mem} -> {:ok, mem}
        {:error, _} -> Memory.new(:local_file, %{})
      end

    case memory_result do
      {:ok, memory} ->
        case Memory.search(memory, query, limit: limit) do
          {:ok, []} ->
            IO.puts("No results found for: \"#{query}\"")

          {:ok, results} ->
            IO.puts("""
            ┌─────────────────────────────────────────────────────────────────────────────────┐
            │                          Memory Search Results                                  │
            └─────────────────────────────────────────────────────────────────────────────────┘

            Query: "#{query}"
            Results: #{length(results)}
            """)

            IO.puts(
              "  " <>
                String.pad_trailing("#", 4) <>
                String.pad_trailing("SCORE", 8) <>
                String.pad_trailing("SOURCE", 20) <>
                "SNIPPET"
            )

            IO.puts("  " <> String.duplicate("─", 76))

            results
            |> Enum.with_index(1)
            |> Enum.each(fn {entry, idx} ->
              score =
                if entry.score do
                  "#{Float.round(entry.score * 100, 1)}%"
                else
                  "—"
                end

              source = truncate(entry.source || "unknown", 18)
              snippet = truncate(String.replace(entry.content || "", ~r/\s+/, " "), 44)

              IO.puts(
                "  " <>
                  String.pad_trailing(to_string(idx), 4) <>
                  String.pad_trailing(score, 8) <>
                  String.pad_trailing(source, 20) <>
                  snippet
              )
            end)

            IO.puts("")

          {:error, reason} ->
            IO.puts("✗ Search failed: #{inspect(reason)}")
        end

      {:error, reason} ->
        IO.puts("✗ Could not initialize memory backend: #{inspect(reason)}")
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

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
    Usage: clawd_ex memory <subcommand> [options]

    Subcommands:
      search <query>    Search agent memory

    Options:
      --help            Show this help message
      -l, --limit N     Limit number of results (default: 10)
    """)
  end

  defp print_search_help do
    IO.puts("""
    Usage: clawd_ex memory search <query> [options]

    Search agent memory for relevant entries.
    Displays matching results with path, score, and content snippet.

    Examples:
      clawd_ex memory search "project setup"
      clawd_ex memory search "API keys" --limit 5

    Options:
      -l, --limit N     Limit number of results (default: 10)
      --help            Show this help message
    """)
  end
end
