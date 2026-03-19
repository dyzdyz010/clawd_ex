defmodule ClawdEx.Tools.MemorySearch do
  @moduledoc """
  记忆语义搜索工具
  """
  @behaviour ClawdEx.Tools.Tool

  alias ClawdEx.Memory

  @impl true
  def name, do: "memory_search"

  @impl true
  def description do
    "Semantically search memory files (MEMORY.md + memory/*.md). Use before answering questions about prior work, decisions, dates, people, preferences, or todos. Returns top snippets with path and lines."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        query: %{
          type: "string",
          description: "Search query"
        },
        max_results: %{
          type: "integer",
          description: "Maximum number of results (default 10)"
        },
        min_score: %{
          type: "number",
          description: "Minimum similarity score 0-1 (default 0.7)"
        }
      },
      required: ["query"]
    }
  end

  @impl true
  def execute(params, context) do
    query = params["query"] || params[:query]
    max_results = params["max_results"] || params[:max_results] || 10
    min_score = params["min_score"] || params[:min_score] || 0.7

    agent_id = context[:agent_id]

    # Try agent-specific memory first, then fallback to Memory.Manager
    results = search_memories(agent_id, query, limit: max_results, min_score: min_score)

    if results == [] do
      {:ok, "No relevant memories found for query: #{query}"}
    else
      formatted =
        results
        |> Enum.map(&format_memory_result/1)
        |> Enum.join("\n")

      {:ok, "Found #{length(results)} relevant memories:\n\n#{formatted}"}
    end
  end

  defp search_memories(agent_id, query, opts) do
    # Try agent-specific Memory backend
    agent_results =
      if agent_id do
        try do
          Memory.search(agent_id, query, opts)
        rescue
          _ -> []
        end
      else
        []
      end

    # If no agent results, try Memory.Manager (unified search across backends)
    if agent_results == [] do
      try do
        case ClawdEx.Memory.Manager.search(query, opts) do
          {:ok, entries} -> entries
          _ -> []
        end
      rescue
        _ -> []
      end
    else
      agent_results
    end
  end

  defp format_memory_result(chunk) when is_map(chunk) do
    # Handle both Memory.Chunk structs and Memory.Backend entries
    source = chunk[:source_file] || chunk[:source] || "unknown"
    start_line = chunk[:start_line] || "?"
    end_line = chunk[:end_line] || "?"
    score = (chunk[:similarity] || chunk[:score] || 0) |> safe_round(3)
    content = chunk[:content] || ""

    """
    ---
    **Source:** #{source} (lines #{start_line}-#{end_line})
    **Score:** #{score}

    #{String.slice(content, 0, 500)}
    """
  end

  defp safe_round(val, decimals) when is_float(val), do: Float.round(val, decimals)
  defp safe_round(val, _decimals), do: val
end
