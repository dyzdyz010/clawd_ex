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

    if is_nil(agent_id) do
      {:error, "No agent context available for memory search"}
    else
      results = Memory.search(agent_id, query, limit: max_results, min_score: min_score)

      if results == [] do
        {:ok, "No relevant memories found for query: #{query}"}
      else
        formatted = results
        |> Enum.map(fn chunk ->
          score = Map.get(chunk, :similarity, 0) |> Float.round(3)
          """
          ---
          **Source:** #{chunk.source_file} (lines #{chunk.start_line}-#{chunk.end_line})
          **Score:** #{score}

          #{String.slice(chunk.content, 0, 500)}
          """
        end)
        |> Enum.join("\n")

        {:ok, "Found #{length(results)} relevant memories:\n\n#{formatted}"}
      end
    end
  end
end
