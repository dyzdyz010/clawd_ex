defmodule ClawdEx.Memory.BM25 do
  @moduledoc """
  BM25 关键词搜索实现

  用于 Hybrid 搜索中的文本匹配部分。
  BM25 擅长精确匹配：ID、代码符号、错误字符串等。
  """

  # BM25 参数
  # 词频饱和参数
  @k1 1.2
  # 文档长度归一化参数
  @b 0.75

  @type document :: %{
          id: any(),
          content: String.t(),
          tokens: [String.t()],
          length: non_neg_integer()
        }

  @type index :: %{
          documents: %{any() => document()},
          idf: %{String.t() => float()},
          avg_doc_length: float(),
          doc_count: non_neg_integer()
        }

  @doc """
  构建 BM25 索引
  """
  @spec build_index([{any(), String.t()}]) :: index()
  def build_index(docs) do
    documents =
      docs
      |> Enum.map(fn {id, content} ->
        tokens = tokenize(content)
        {id, %{id: id, content: content, tokens: tokens, length: length(tokens)}}
      end)
      |> Map.new()

    doc_count = map_size(documents)

    avg_doc_length =
      if doc_count > 0 do
        total_length = documents |> Map.values() |> Enum.map(& &1.length) |> Enum.sum()
        total_length / doc_count
      else
        0.0
      end

    # 计算 IDF (Inverse Document Frequency)
    idf = calculate_idf(documents, doc_count)

    %{
      documents: documents,
      idf: idf,
      avg_doc_length: avg_doc_length,
      doc_count: doc_count
    }
  end

  @doc """
  使用 BM25 搜索
  返回 [{id, score}] 按分数降序排列
  """
  @spec search(index(), String.t(), keyword()) :: [{any(), float()}]
  def search(index, query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    query_tokens = tokenize(query)

    if Enum.empty?(query_tokens) or index.doc_count == 0 do
      []
    else
      index.documents
      |> Enum.map(fn {id, doc} ->
        score = calculate_bm25_score(query_tokens, doc, index)
        {id, score}
      end)
      |> Enum.filter(fn {_, score} -> score > 0 end)
      |> Enum.sort_by(fn {_, score} -> score end, :desc)
      |> Enum.take(limit)
    end
  end

  @doc """
  将 BM25 分数归一化到 0-1 范围
  使用 sigmoid 变换: score / (1 + score)
  """
  @spec normalize_score(float()) :: float()
  def normalize_score(score) when score > 0, do: score / (1 + score)
  def normalize_score(_), do: 0.0

  # 分词：支持中英文
  defp tokenize(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^\w\s\p{Han}\p{Hiragana}\p{Katakana}]+/u, " ")
    |> String.split(~r/\s+/, trim: true)
    # 过滤太短的词
    |> Enum.reject(&(String.length(&1) < 2))
    # 用于 IDF 计算时需要去重
    |> Enum.uniq()
  end

  # 分词但保留重复（用于词频计算）
  defp tokenize_with_freq(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^\w\s\p{Han}\p{Hiragana}\p{Katakana}]+/u, " ")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(&(String.length(&1) < 2))
  end

  # 计算 IDF
  defp calculate_idf(documents, doc_count) do
    # 统计每个词出现在多少文档中
    doc_freq =
      documents
      |> Map.values()
      |> Enum.flat_map(fn doc -> doc.tokens |> Enum.uniq() end)
      |> Enum.frequencies()

    # 计算 IDF: log((N - n + 0.5) / (n + 0.5) + 1)
    doc_freq
    |> Enum.map(fn {term, freq} ->
      idf = :math.log((doc_count - freq + 0.5) / (freq + 0.5) + 1)
      # IDF 不应为负
      {term, max(idf, 0)}
    end)
    |> Map.new()
  end

  # 计算文档的 BM25 分数
  defp calculate_bm25_score(query_tokens, doc, index) do
    doc_tokens = tokenize_with_freq(doc.content)
    term_freq = Enum.frequencies(doc_tokens)

    query_tokens
    |> Enum.map(fn term ->
      tf = Map.get(term_freq, term, 0)
      idf = Map.get(index.idf, term, 0)

      if tf > 0 and idf > 0 do
        # BM25 公式
        numerator = tf * (@k1 + 1)
        denominator = tf + @k1 * (1 - @b + @b * (doc.length / max(index.avg_doc_length, 1)))
        idf * (numerator / denominator)
      else
        0.0
      end
    end)
    |> Enum.sum()
  end
end
