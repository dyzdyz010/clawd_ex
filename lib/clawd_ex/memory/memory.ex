defmodule ClawdEx.Memory do
  @moduledoc """
  记忆服务 - 向量语义搜索和记忆管理
  """
  import Ecto.Query
  alias ClawdEx.Repo
  alias ClawdEx.Memory.Chunk
  alias ClawdEx.AI.Embeddings

  @doc """
  语义搜索记忆块
  """
  @spec search(integer(), String.t(), keyword()) :: [Chunk.t()]
  def search(agent_id, query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    min_score = Keyword.get(opts, :min_score, 0.7)

    case Embeddings.generate(query) do
      {:ok, query_embedding} ->
        query_embedding_str = "[#{Enum.join(query_embedding, ",")}]"

        # 使用 pgvector 的余弦相似度搜索
        from(c in Chunk,
          where: c.agent_id == ^agent_id,
          where: not is_nil(c.embedding),
          select: %{
            chunk: c,
            similarity: fragment(
              "1 - (embedding <=> ?::vector)",
              ^query_embedding_str
            )
          },
          order_by: [asc: fragment("embedding <=> ?::vector", ^query_embedding_str)],
          limit: ^limit
        )
        |> Repo.all()
        |> Enum.filter(fn %{similarity: sim} -> sim >= min_score end)
        |> Enum.map(fn %{chunk: chunk, similarity: sim} ->
          Map.put(chunk, :similarity, sim)
        end)

      {:error, _reason} ->
        []
    end
  end

  @doc """
  索引新的记忆内容
  """
  @spec index_content(integer(), String.t(), String.t(), keyword()) :: {:ok, [Chunk.t()]} | {:error, term()}
  def index_content(agent_id, source_file, content, opts \\ []) do
    source_type = Keyword.get(opts, :source_type, :memory_file)
    chunk_size = Keyword.get(opts, :chunk_size, 400)  # tokens
    overlap = Keyword.get(opts, :overlap, 80)  # tokens

    chunks = chunk_text(content, chunk_size, overlap)

    results =
      chunks
      |> Enum.with_index()
      |> Enum.map(fn {{text, start_line, end_line}, _idx} ->
        case Embeddings.generate(text) do
          {:ok, embedding} ->
            %{
              agent_id: agent_id,
              content: text,
              source_file: source_file,
              source_type: source_type,
              start_line: start_line,
              end_line: end_line,
              embedding: embedding,
              embedding_model: Embeddings.model(),
              inserted_at: DateTime.utc_now(),
              updated_at: DateTime.utc_now()
            }

          {:error, _} ->
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    case results do
      [] ->
        {:error, :no_chunks_indexed}

      chunks_data ->
        {_count, inserted} = Repo.insert_all(Chunk, chunks_data, returning: true)
        {:ok, inserted}
    end
  end

  @doc """
  删除指定来源的记忆块
  """
  @spec delete_by_source(integer(), String.t()) :: {integer(), nil}
  def delete_by_source(agent_id, source_file) do
    from(c in Chunk,
      where: c.agent_id == ^agent_id,
      where: c.source_file == ^source_file
    )
    |> Repo.delete_all()
  end

  @doc """
  获取指定记忆文件内容
  """
  @spec get_content(integer(), String.t(), keyword()) :: String.t() | nil
  def get_content(agent_id, source_file, opts \\ []) do
    from_line = Keyword.get(opts, :from, nil)
    limit_lines = Keyword.get(opts, :lines, nil)

    query =
      from(c in Chunk,
        where: c.agent_id == ^agent_id,
        where: c.source_file == ^source_file,
        order_by: [asc: c.start_line],
        select: c.content
      )

    query =
      if from_line do
        from(c in query, where: c.start_line >= ^from_line)
      else
        query
      end

    query =
      if limit_lines do
        from(c in query, limit: ^limit_lines)
      else
        query
      end

    Repo.all(query) |> Enum.join("\n")
  end

  # 将文本分割成带有行号的块
  defp chunk_text(content, _chunk_size, _overlap) do
    lines = String.split(content, "\n")

    # 简单的按行分块，后续可以改进为基于 token 的分块
    lines
    |> Enum.with_index(1)
    |> Enum.chunk_every(20, 15, :discard)  # 每20行一块，15行重叠
    |> Enum.map(fn chunk ->
      texts = Enum.map(chunk, fn {line, _idx} -> line end)
      start_line = chunk |> List.first() |> elem(1)
      end_line = chunk |> List.last() |> elem(1)
      {Enum.join(texts, "\n"), start_line, end_line}
    end)
  end
end
