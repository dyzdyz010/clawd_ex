defmodule ClawdEx.Memory.Backends.MemOS do
  @moduledoc """
  MemOS 远程记忆后端

  对接 MemOS API (https://memos.memtensor.cn)，支持：
  - 语义搜索记忆
  - 对话消息存储
  - 多 Agent 共享记忆池

  ## 配置
  ```
  %{
    api_key: "mpg-xxx",
    user_id: "dyzdyz010",
    base_url: "https://memos.memtensor.cn/api/openmem/v1"
  }
  ```
  """

  @behaviour ClawdEx.Memory.Backend

  require Logger

  @default_base_url "https://memos.memtensor.cn/api/openmem/v1"
  @timeout 30_000

  defstruct [:api_key, :user_id, :base_url, :http_client]

  @impl true
  def name, do: :memos

  @impl true
  def init(config) do
    api_key = Map.get(config, :api_key) || Map.get(config, "api_key")
    user_id = Map.get(config, :user_id) || Map.get(config, "user_id") || "default"
    base_url = Map.get(config, :base_url) || Map.get(config, "base_url") || @default_base_url

    if is_nil(api_key) or api_key == "" do
      {:error, :missing_api_key}
    else
      state = %__MODULE__{
        api_key: api_key,
        user_id: user_id,
        base_url: String.trim_trailing(base_url, "/"),
        http_client: Map.get(config, :http_client, Req)
      }

      {:ok, state}
    end
  end

  @impl true
  def search(state, query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)

    body = %{
      user_id: state.user_id,
      query: query,
      top_k: limit
    }

    case post(state, "/search/memory", body) do
      {:ok, %{"code" => 0, "data" => data}} ->
        # MemOS 返回多种记忆类型
        memories = Map.get(data, "memory_detail_list", [])
        preferences = Map.get(data, "preference_detail_list", [])

        entries =
          (Enum.map(memories, &parse_memory_entry/1) ++
             Enum.map(preferences, &parse_preference_entry/1))
          |> Enum.sort_by(& &1.score, :desc)
          |> filter_by_opts(opts)

        {:ok, entries}

      {:ok, %{"code" => code, "message" => msg}} when code != 0 ->
        Logger.warning("MemOS search failed: code=#{code} msg=#{msg}")
        {:error, {:api_error, code, msg}}

      {:error, reason} ->
        Logger.warning("MemOS search request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl true
  def store(state, content, opts \\ []) do
    conversation_id = Keyword.get(opts, :conversation_id, generate_conversation_id())
    source = Keyword.get(opts, :source, "clawd_ex")

    messages = [
      %{role: "assistant", content: "[#{source}] #{content}"}
    ]

    store_messages(state, messages, Keyword.put(opts, :conversation_id, conversation_id))
    |> case do
      {:ok, [entry | _]} -> {:ok, entry}
      {:ok, []} -> {:error, :no_entry_created}
      error -> error
    end
  end

  @impl true
  def store_messages(state, messages, opts \\ []) do
    conversation_id = Keyword.get(opts, :conversation_id, generate_conversation_id())

    body = %{
      user_id: state.user_id,
      conversation_id: conversation_id,
      messages: messages
    }

    case post(state, "/add/message", body) do
      {:ok, %{"code" => 0, "data" => %{"success" => true}}} ->
        # MemOS 不返回具体条目，构造虚拟条目
        entries =
          messages
          |> Enum.map(fn msg ->
            %{
              id: "memos_#{conversation_id}_#{:erlang.unique_integer([:positive])}",
              content: msg["content"] || msg[:content],
              type: :episodic,
              source: "memos",
              metadata: %{
                role: msg["role"] || msg[:role],
                conversation_id: conversation_id
              },
              embedding: nil,
              score: nil,
              created_at: DateTime.utc_now(),
              updated_at: DateTime.utc_now()
            }
          end)

        {:ok, entries}

      {:ok, %{"code" => code, "message" => msg}} ->
        Logger.warning("MemOS store failed: code=#{code} msg=#{msg}")
        {:error, {:api_error, code, msg}}

      {:error, reason} ->
        Logger.warning("MemOS store request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl true
  def delete(_state, _id) do
    # MemOS API 可能不支持单条删除
    {:error, :not_supported}
  end

  @impl true
  def delete_by_source(_state, _source) do
    # MemOS API 可能不支持按来源删除
    {:error, :not_supported}
  end

  @impl true
  def health(state) do
    # 简单的健康检查：尝试一次空搜索
    case search(state, "health_check", limit: 1) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Private helpers

  defp post(state, path, body) do
    url = "#{state.base_url}#{path}"

    headers = [
      {"content-type", "application/json"},
      {"authorization", "Token #{state.api_key}"}
    ]

    case state.http_client.post(url, json: body, headers: headers, receive_timeout: @timeout) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        case Jason.decode(body) do
          {:ok, decoded} -> {:ok, decoded}
          {:error, _} -> {:error, :invalid_json}
        end

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, exception} ->
        {:error, exception}
    end
  end

  defp parse_memory_entry(mem) do
    # MemOS memory_detail_list 格式
    # memory_key: 标题, memory_value: 内容, relativity: 相关性分数
    %{
      id: mem["id"] || "memos_#{:erlang.unique_integer([:positive])}",
      content: build_content(mem["memory_key"], mem["memory_value"]),
      type: parse_memory_type(mem["memory_type"]),
      source: "memos:#{mem["conversation_id"] || "unknown"}",
      metadata: %{
        tags: mem["tags"] || [],
        confidence: mem["confidence"],
        memory_type: mem["memory_type"]
      },
      embedding: nil,
      score: mem["relativity"] || 0.0,
      created_at: parse_timestamp(mem["create_time"]),
      updated_at: parse_timestamp(mem["update_time"])
    }
  end

  defp parse_preference_entry(pref) do
    # MemOS preference_detail_list 格式
    %{
      id: pref["id"] || "memos_pref_#{:erlang.unique_integer([:positive])}",
      content: "#{pref["preference"]}\n\nReasoning: #{pref["reasoning"]}",
      type: :semantic,
      source: "memos:preference",
      metadata: %{
        preference_type: pref["preference_type"],
        conversation_id: pref["conversation_id"]
      },
      embedding: nil,
      score: pref["relativity"] || 0.0,
      created_at: parse_timestamp(pref["create_time"]),
      updated_at: parse_timestamp(pref["update_time"])
    }
  end

  defp build_content(nil, value), do: value || ""
  defp build_content(key, nil), do: key
  defp build_content(key, value), do: "**#{key}**\n\n#{value}"

  defp parse_memory_type("LongTermMemory"), do: :semantic
  defp parse_memory_type("WorkingMemory"), do: :episodic
  defp parse_memory_type(_), do: :episodic

  defp parse_datetime(nil), do: DateTime.utc_now()

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp parse_datetime(_), do: DateTime.utc_now()

  # 解析毫秒时间戳
  defp parse_timestamp(nil), do: DateTime.utc_now()

  defp parse_timestamp(ms) when is_integer(ms) do
    case DateTime.from_unix(div(ms, 1000)) do
      {:ok, dt} -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp parse_timestamp(_), do: DateTime.utc_now()

  defp filter_by_opts(entries, opts) do
    min_score = Keyword.get(opts, :min_score, 0.0)
    types = Keyword.get(opts, :types, nil)
    sources = Keyword.get(opts, :sources, nil)
    after_dt = Keyword.get(opts, :after, nil)
    before_dt = Keyword.get(opts, :before, nil)

    entries
    |> Enum.filter(fn e ->
      (is_nil(min_score) or (e.score || 0) >= min_score) and
        (is_nil(types) or e.type in types) and
        (is_nil(sources) or e.source in sources) and
        (is_nil(after_dt) or DateTime.compare(e.created_at, after_dt) in [:gt, :eq]) and
        (is_nil(before_dt) or DateTime.compare(e.created_at, before_dt) in [:lt, :eq])
    end)
  end

  defp generate_conversation_id do
    "clawd_#{DateTime.utc_now() |> DateTime.to_unix()}_#{:rand.uniform(10000)}"
  end
end
