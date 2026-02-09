defmodule ClawdEx.Tools.MemoryTool do
  @moduledoc """
  记忆工具 - 供 Agent 调用的记忆操作

  提供三个主要操作：
  - `search` - 语义搜索记忆
  - `store` - 存储记忆
  - `status` - 查看记忆状态
  """

  @behaviour ClawdEx.Tools.Tool

  alias ClawdEx.Memory

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
  def execute(params, context) do
    action = params["action"]

    # 从 context 获取 memory 实例，或创建默认实例
    memory = get_memory(context)

    case action do
      "search" -> do_search(memory, params)
      "store" -> do_store(memory, params)
      "status" -> do_status(memory)
      _ -> {:error, "Unknown action: #{action}"}
    end
  end

  defp get_memory(context) do
    case context[:memory] do
      nil ->
        # 没有传入 memory，创建默认实例
        case Memory.new(:local_file, Memory.Config.local_file()) do
          {:ok, m} -> m
          _ -> nil
        end

      memory ->
        memory
    end
  end

  defp do_search(nil, _params), do: {:error, "Memory not initialized"}

  defp do_search(memory, params) do
    query = params["query"]

    if is_nil(query) or query == "" do
      {:error, "Missing required parameter: query"}
    else
      opts = [
        limit: params["limit"] || 5,
        min_score: params["min_score"] || 0.3
      ]

      case Memory.search(memory, query, opts) do
        {:ok, memories} ->
          formatted = format_search_results(memories)
          {:ok, formatted}

        {:error, reason} ->
          {:error, "Search failed: #{inspect(reason)}"}
      end
    end
  end

  defp do_store(nil, _params), do: {:error, "Memory not initialized"}

  defp do_store(memory, params) do
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

      case Memory.store(memory, content, opts) do
        {:ok, entry} ->
          {:ok, "Memory stored (id: #{entry.id}, backend: #{Memory.backend_name(memory)})"}

        {:error, reason} ->
          {:error, "Store failed: #{inspect(reason)}"}
      end
    end
  end

  defp do_status(nil), do: {:error, "Memory not initialized"}

  defp do_status(memory) do
    backend = Memory.backend_name(memory)
    health = Memory.health(memory)

    health_str =
      case health do
        :ok -> "✓ healthy"
        {:error, reason} -> "✗ #{inspect(reason)}"
      end

    result = """
    ## Memory Status

    - **Backend**: #{backend}
    - **Health**: #{health_str}
    - **Available backends**: #{Enum.join(Memory.list_backends(), ", ")}
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
