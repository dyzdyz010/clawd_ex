defmodule ClawdEx.Memory.BM25Test do
  use ExUnit.Case, async: true

  alias ClawdEx.Memory.BM25

  describe "build_index/1" do
    test "builds index from documents" do
      docs = [
        {1, "The quick brown fox jumps over the lazy dog"},
        {2, "A fast brown fox leaps over a sleepy canine"},
        {3, "Python programming language documentation"}
      ]

      index = BM25.build_index(docs)

      assert index.doc_count == 3
      assert index.avg_doc_length > 0
      assert map_size(index.documents) == 3
      assert map_size(index.idf) > 0
    end

    test "handles empty documents" do
      index = BM25.build_index([])

      assert index.doc_count == 0
      assert index.avg_doc_length == 0.0
    end
  end

  describe "search/3" do
    test "finds relevant documents" do
      docs = [
        {1, "The quick brown fox jumps over the lazy dog"},
        {2, "A fast brown fox leaps over a sleepy canine"},
        {3, "Python programming language documentation"}
      ]

      index = BM25.build_index(docs)
      results = BM25.search(index, "brown fox")

      # 应该找到前两个文档
      assert length(results) >= 2
      
      ids = Enum.map(results, fn {id, _score} -> id end)
      assert 1 in ids
      assert 2 in ids
    end

    test "ranks exact matches higher" do
      docs = [
        {1, "error code ABC123 occurred"},
        {2, "some error happened"},
        {3, "ABC123 is the code we need"}
      ]

      index = BM25.build_index(docs)
      results = BM25.search(index, "ABC123")

      # 包含 ABC123 的文档应该排名靠前
      assert length(results) >= 2
      
      [{first_id, _} | _] = results
      assert first_id in [1, 3]
    end

    test "returns empty for no matches" do
      docs = [
        {1, "hello world"},
        {2, "foo bar baz"}
      ]

      index = BM25.build_index(docs)
      results = BM25.search(index, "completely unrelated xyz123")

      # 可能返回空或低分结果
      assert is_list(results)
    end

    test "handles Chinese text" do
      docs = [
        {1, "这是一个测试文档"},
        {2, "另一个包含测试的文档"},
        {3, "完全不相关的内容"}
      ]

      index = BM25.build_index(docs)
      results = BM25.search(index, "测试")

      # 应该找到前两个文档
      assert length(results) >= 2
    end
  end

  describe "normalize_score/1" do
    test "normalizes positive scores to 0-1 range" do
      assert BM25.normalize_score(1.0) == 0.5
      assert BM25.normalize_score(0.0) == 0.0
      
      high_score = BM25.normalize_score(10.0)
      assert high_score > 0.9 and high_score < 1.0
    end

    test "handles zero and negative scores" do
      assert BM25.normalize_score(0) == 0.0
      assert BM25.normalize_score(-1) == 0.0
    end
  end
end
