defmodule ClawdEx.Memory.Backends.PgVector do
  @moduledoc """
  PostgreSQL + pgvector 本地向量存储后端

  支持高性能的本地语义搜索，适合：
  - 大量结构化记忆存储
  - 低延迟检索需求
  - 完全本地化部署

  ## 配置
  ```
  %{
    repo: ClawdEx.Repo,
    embedding_model: "text-embedding-3-small"
  }
  ```
  """

  @behaviour ClawdEx.Memory.Backend

  import Ecto.Query
  require Logger

  alias ClawdEx.Memory.Chunk
  alias ClawdEx.AI.Embeddings

  defstruct [:repo, :embedding_model]

  @impl true
  def name, do: :pgvector

  @impl true
  def init(config) do
    repo = Map.get(config, :repo) || Map.get(config, "repo") || ClawdEx.Repo
    embedding_model = Map.get(config, :embedding_model) || Embeddings.model()

    state = %__MODULE__{
      repo: repo,
      embedding_model: embedding_model
    }

    {:ok, state}
  end

  @impl true
  def search(state, query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    min_score = Keyword.get(opts, :min_score, 0.5)
    types = Keyword.get(opts, :types, nil)
    sources = Keyword.get(opts, :sources, nil)

    case Embeddings.generate(query) do
      {:ok, query_embedding} ->
        query_embedding_str = "[#{Enum.join(query_embedding, ",")}]"

        base_query =
          from(c in Chunk,
            where: not is_nil(c.embedding),
            select: %{
              chunk: c,
              similarity:
                fragment(
                  "1 - (embedding <=> ?::vector)",
                  ^query_embedding_str
                )
            },
            order_by: [asc: fragment("embedding <=> ?::vector", ^query_embedding_str)],
            limit: ^limit
          )

        # 应用类型过滤
        base_query =
          if types do
            type_strings = Enum.map(types, &to_string/1)
            from([c] in base_query, where: c.source_type in ^type_strings)
          else
            base_query
          end

        # 应用来源过滤
        base_query =
          if sources do
            from([c] in base_query, where: c.source_file in ^sources)
          else
            base_query
          end

        entries =
          base_query
          |> state.repo.all()
          |> Enum.filter(fn %{similarity: sim} -> sim >= min_score end)
          |> Enum.map(&chunk_to_entry/1)

        {:ok, entries}

      {:error, reason} ->
        Logger.warning("PgVector search embedding failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl true
  def store(state, content, opts \\ []) do
    source = Keyword.get(opts, :source, "unknown")
    type = Keyword.get(opts, :type, :episodic)
    metadata = Keyword.get(opts, :metadata, %{})

    case Embeddings.generate(content) do
      {:ok, embedding} ->
        now = DateTime.utc_now()

        chunk_data = %{
          content: content,
          source_file: source,
          source_type: to_string(type),
          start_line: 1,
          end_line: 1,
          embedding: embedding,
          embedding_model: state.embedding_model,
          metadata: metadata,
          inserted_at: now,
          updated_at: now
        }

        case state.repo.insert(Chunk.changeset(%Chunk{}, chunk_data)) do
          {:ok, chunk} ->
            entry = %{
              id: "pgvector_#{chunk.id}",
              content: chunk.content,
              type: String.to_existing_atom(chunk.source_type),
              source: chunk.source_file,
              metadata: chunk.metadata || %{},
              embedding: chunk.embedding,
              score: nil,
              created_at: chunk.inserted_at,
              updated_at: chunk.updated_at
            }

            {:ok, entry}

          {:error, changeset} ->
            {:error, {:changeset_error, changeset}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def store_messages(state, messages, opts \\ []) do
    # 将消息序列化为单个内容块
    content =
      messages
      |> Enum.map(fn msg ->
        role = msg["role"] || msg[:role] || "unknown"
        text = msg["content"] || msg[:content] || ""
        "[#{role}] #{text}"
      end)
      |> Enum.join("\n\n")

    case store(state, content, opts) do
      {:ok, entry} -> {:ok, [entry]}
      error -> error
    end
  end

  @impl true
  def delete(state, id) do
    # 提取数字 ID
    chunk_id =
      case id do
        "pgvector_" <> num -> String.to_integer(num)
        num when is_integer(num) -> num
        num when is_binary(num) -> String.to_integer(num)
      end

    case state.repo.get(Chunk, chunk_id) do
      nil ->
        {:error, :not_found}

      chunk ->
        case state.repo.delete(chunk) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @impl true
  def delete_by_source(state, source) do
    {count, _} =
      from(c in Chunk, where: c.source_file == ^source)
      |> state.repo.delete_all()

    {:ok, count}
  end

  @impl true
  def health(state) do
    case state.repo.query("SELECT 1") do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Private helpers

  defp chunk_to_entry(%{chunk: chunk, similarity: similarity}) do
    %{
      id: "pgvector_#{chunk.id}",
      content: chunk.content,
      type: parse_type(chunk.source_type),
      source: chunk.source_file,
      metadata: %{
        start_line: chunk.start_line,
        end_line: chunk.end_line,
        agent_id: chunk.agent_id
      },
      embedding: chunk.embedding,
      score: similarity,
      created_at: chunk.inserted_at,
      updated_at: chunk.updated_at
    }
  end

  defp parse_type(nil), do: :episodic
  defp parse_type("episodic"), do: :episodic
  defp parse_type("semantic"), do: :semantic
  defp parse_type("procedural"), do: :procedural
  defp parse_type(_), do: :episodic
end
