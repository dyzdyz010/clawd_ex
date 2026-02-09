defmodule ClawdEx.Tools.MemoryTool do
  @moduledoc """
  记忆工具 - 供 Agent 调用的记忆操作

  提供三个主要操作：
  - `memory_search` - 语义搜索记忆
  - `memory_store` - 存储记忆
  - `memory_status` - 查看记忆系统状态
  """

  @behaviour ClawdEx.Tools.Tool

  alias ClawdEx.Memory.{Manager, AgentMemory}

  @impl true
  def name, do: "memory"

  @impl true
  def description do
    """
    Unified memory system for searching and storing memories across multiple backends (local files, MemOS, pgvector).

    Actions:
    - search: Semantic search for relevant memories
    - store: Store new memory
    - status: Check memory system status
    """
  end

  @impl true
  def parameters do
    %{
      type: "object",
      required: ["action"],
      properties: %{
        action: %{
          type: "string",
          enum: ["search", "store", "status"],
          description: "Memory action to perform"
        },
        query: %{
          type: "string",
          description: "Search query (required for 'search' action)"
        },
        content: %{
          type: "string",
          description: "Content to store (required for 'store' action)"
        },
        type: %{
          type: "string",
          enum: ["episodic", "semantic", "procedural"],
          description: "Memory type for storage (default: episodic)"
        },
        limit: %{
          type: "integer",
          description: "Maximum results to return (default: 5)"
        },
        min_score: %{
          type: "number",
          description: "Minimum relevance score 0-1 (default: 0.3)"
        },
        source: %{
          type: "string",
          description: "Source identifier for storage"
        }
      }
    }
  end

  @impl true
  def execute(params, _context) do
    action = params["action"]

    case action do
      "search" -> do_search(params)
      "store" -> do_store(params)
      "status" -> do_status()
      _ -> {:error, "Unknown action: #{action}"}
    end
  end

  defp do_search(params) do
    query = params["query"]

    if is_nil(query) or query == "" do
      {:error, "Missing required parameter: query"}
    else
      opts = [
        limit: params["limit"] || 5,
        min_score: params["min_score"] || 0.3
      ]

      case AgentMemory.recall(query, opts) do
        {:ok, memories} ->
          formatted = format_search_results(memories)
          {:ok, formatted}

        {:error, reason} ->
          {:error, "Search failed: #{inspect(reason)}"}
      end
    end
  end

  defp do_store(params) do
    content = params["content"]

    if is_nil(content) or content == "" do
      {:error, "Missing required parameter: content"}
    else
      type =
        case params["type"] do
          "semantic" -> :semantic
          "procedural" -> :procedural
          _ -> :episodic
        end

      opts = [
        type: type,
        source: params["source"] || "agent_tool"
      ]

      case Manager.store(content, opts) do
        {:ok, entry} ->
          {:ok, "Memory stored successfully (id: #{entry.id}, backend: #{entry[:backend] || "unknown"})"}

        {:error, reason} ->
          {:error, "Store failed: #{inspect(reason)}"}
      end
    end
  end

  defp do_status do
    status = Manager.status()
    health = Manager.health()

    backends_info =
      status.backends
      |> Enum.map(fn {name, info} ->
        health_status =
          case Map.get(health, name) do
            :ok -> "✓ healthy"
            {:error, reason} -> "✗ #{inspect(reason)}"
          end

        "- #{name}: #{info.module} (#{health_status})"
      end)
      |> Enum.join("\n")

    routing_info =
      status.routing
      |> Enum.map(fn {type, backends} ->
        "- #{type}: #{Enum.join(backends, " → ")}"
      end)
      |> Enum.join("\n")

    result = """
    ## Memory System Status

    ### Backends
    #{backends_info}

    ### Routing
    #{routing_info}
    """

    {:ok, result}
  end

  defp format_search_results([]) do
    "No relevant memories found."
  end

  defp format_search_results(memories) do
    results =
      memories
      |> Enum.with_index(1)
      |> Enum.map(fn {mem, idx} ->
        score = Float.round((mem.score || 0) * 100, 1)
        source = mem.source || "unknown"
        backend = mem[:backend] || "unknown"
        content = String.slice(mem.content || "", 0, 300)
        content = if String.length(mem.content || "") > 300, do: content <> "...", else: content

        """
        ### #{idx}. [#{source}] (#{score}% via #{backend})
        #{content}
        """
      end)
      |> Enum.join("\n")

    "## Search Results\n\n#{results}"
  end
end
