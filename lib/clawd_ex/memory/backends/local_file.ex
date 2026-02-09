defmodule ClawdEx.Memory.Backends.LocalFile do
  @moduledoc """
  本地文件记忆后端

  基于 Markdown 文件的轻量级记忆存储，支持：
  - BM25 关键词搜索
  - 文件系统持久化
  - 零依赖部署

  ## 配置
  ```
  %{
    workspace: "~/.clawd/workspace",
    memory_dir: "memory",          # 相对于 workspace
    memory_file: "MEMORY.md"       # 主记忆文件
  }
  ```

  ## 目录结构
  ```
  workspace/
  ├── MEMORY.md           # 长期记忆
  └── memory/
      ├── 2024-01-15.md   # 日常记忆
      ├── 2024-01-16.md
      └── ...
  ```
  """

  @behaviour ClawdEx.Memory.Backend

  require Logger

  alias ClawdEx.Memory.BM25

  defstruct [:workspace, :memory_dir, :memory_file, :index]

  @impl true
  def name, do: :local_file

  @impl true
  def init(config) do
    workspace =
      (Map.get(config, :workspace) || Map.get(config, "workspace") || "~/.clawd/workspace")
      |> Path.expand()

    memory_dir = Map.get(config, :memory_dir) || Map.get(config, "memory_dir") || "memory"
    memory_file = Map.get(config, :memory_file) || Map.get(config, "memory_file") || "MEMORY.md"

    # 确保目录存在
    full_memory_dir = Path.join(workspace, memory_dir)
    File.mkdir_p!(full_memory_dir)

    state = %__MODULE__{
      workspace: workspace,
      memory_dir: memory_dir,
      memory_file: memory_file,
      index: nil
    }

    {:ok, state}
  end

  @impl true
  def search(state, query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    min_score = Keyword.get(opts, :min_score, 0.1)
    sources = Keyword.get(opts, :sources, nil)

    # 收集所有记忆文件
    files = list_memory_files(state, sources)

    # 加载并索引文档
    documents =
      files
      |> Enum.flat_map(fn file ->
        case File.read(file) do
          {:ok, content} ->
            parse_document(file, content, state.workspace)

          {:error, _} ->
            []
        end
      end)

    if Enum.empty?(documents) do
      {:ok, []}
    else
      # 构建 BM25 索引
      indexed_docs =
        documents
        |> Enum.with_index()
        |> Enum.map(fn {doc, idx} -> {idx, doc.content} end)

      index = BM25.build_index(indexed_docs)

      # 搜索
      results = BM25.search(index, query, limit: limit * 2)

      entries =
        results
        |> Enum.map(fn {idx, score} ->
          doc = Enum.at(documents, idx)
          # 归一化分数到 0-1
          normalized_score = BM25.normalize_score(score)
          Map.put(doc, :score, normalized_score)
        end)
        |> Enum.filter(fn e -> e.score >= min_score end)
        |> Enum.take(limit)

      {:ok, entries}
    end
  end

  @impl true
  def store(state, content, opts \\ []) do
    source = Keyword.get(opts, :source, nil)
    type = Keyword.get(opts, :type, :episodic)

    # 确定目标文件
    target_file =
      case source do
        nil ->
          # 默认写入今天的日常记忆
          date = Date.utc_today() |> Date.to_iso8601()
          Path.join([state.workspace, state.memory_dir, "#{date}.md"])

        "MEMORY.md" ->
          Path.join(state.workspace, state.memory_file)

        path ->
          if Path.type(path) == :absolute do
            path
          else
            Path.join(state.workspace, path)
          end
      end

    # 确保目录存在
    File.mkdir_p!(Path.dirname(target_file))

    # 格式化内容
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
    formatted = format_entry(content, type, timestamp)

    # 追加到文件
    case File.write(target_file, formatted, [:append]) do
      :ok ->
        entry = %{
          id: "local_#{:erlang.unique_integer([:positive])}",
          content: content,
          type: type,
          source: Path.relative_to(target_file, state.workspace),
          metadata: %{timestamp: timestamp},
          embedding: nil,
          score: nil,
          created_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        }

        {:ok, entry}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def store_messages(state, messages, opts \\ []) do
    # 格式化消息为 Markdown
    content =
      messages
      |> Enum.map(fn msg ->
        role = msg["role"] || msg[:role] || "unknown"
        text = msg["content"] || msg[:content] || ""
        "**#{String.capitalize(role)}:** #{text}"
      end)
      |> Enum.join("\n\n")

    case store(state, content, opts) do
      {:ok, entry} -> {:ok, [entry]}
      error -> error
    end
  end

  @impl true
  def delete(_state, _id) do
    # 本地文件不支持单条删除（需要解析和重写文件）
    {:error, :not_supported}
  end

  @impl true
  def delete_by_source(state, source) do
    file_path =
      if Path.type(source) == :absolute do
        source
      else
        Path.join(state.workspace, source)
      end

    case File.rm(file_path) do
      :ok -> {:ok, 1}
      {:error, :enoent} -> {:ok, 0}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def health(_state) do
    :ok
  end

  # Private helpers

  defp list_memory_files(state, nil) do
    memory_dir = Path.join(state.workspace, state.memory_dir)
    main_file = Path.join(state.workspace, state.memory_file)

    daily_files =
      case File.ls(memory_dir) do
        {:ok, files} ->
          files
          |> Enum.filter(&String.ends_with?(&1, ".md"))
          |> Enum.map(&Path.join(memory_dir, &1))

        {:error, _} ->
          []
      end

    if File.exists?(main_file) do
      [main_file | daily_files]
    else
      daily_files
    end
  end

  defp list_memory_files(state, sources) when is_list(sources) do
    sources
    |> Enum.map(fn source ->
      if Path.type(source) == :absolute do
        source
      else
        Path.join(state.workspace, source)
      end
    end)
    |> Enum.filter(&File.exists?/1)
  end

  defp parse_document(file_path, content, workspace) do
    relative_path = Path.relative_to(file_path, workspace)
    lines = String.split(content, "\n")

    # 按段落分割（双换行或标题分隔）
    chunks = chunk_by_sections(lines)

    chunks
    |> Enum.with_index()
    |> Enum.map(fn {{text, start_line, end_line}, _idx} ->
      %{
        id: "local_#{:erlang.phash2({file_path, start_line})}",
        content: text,
        type: :episodic,
        source: relative_path,
        metadata: %{
          start_line: start_line,
          end_line: end_line
        },
        embedding: nil,
        score: 0.0,
        created_at: get_file_time(file_path),
        updated_at: get_file_time(file_path)
      }
    end)
    |> Enum.reject(fn doc -> String.trim(doc.content) == "" end)
  end

  defp chunk_by_sections(lines) do
    lines
    |> Enum.with_index(1)
    |> Enum.chunk_while(
      [],
      fn {line, idx}, acc ->
        # 新段落：遇到标题或空行后的内容
        if String.starts_with?(line, "#") and acc != [] do
          {:cont, Enum.reverse(acc), [{line, idx}]}
        else
          {:cont, [{line, idx} | acc]}
        end
      end,
      fn
        [] -> {:cont, []}
        acc -> {:cont, Enum.reverse(acc), []}
      end
    )
    |> Enum.map(fn chunk ->
      texts = Enum.map(chunk, fn {line, _} -> line end)
      start_line = chunk |> List.first() |> elem(1)
      end_line = chunk |> List.last() |> elem(1)
      {Enum.join(texts, "\n"), start_line, end_line}
    end)
    |> Enum.reject(fn {text, _, _} -> String.trim(text) == "" end)
  end

  defp get_file_time(path) do
    case File.stat(path) do
      {:ok, %{mtime: mtime}} ->
        mtime
        |> NaiveDateTime.from_erl!()
        |> DateTime.from_naive!("Etc/UTC")

      {:error, _} ->
        DateTime.utc_now()
    end
  end

  defp format_entry(content, type, timestamp) do
    type_tag =
      case type do
        :episodic -> "📝"
        :semantic -> "💡"
        :procedural -> "⚙️"
        _ -> "📝"
      end

    """

    ---
    #{type_tag} [#{timestamp}]

    #{content}
    """
  end
end
