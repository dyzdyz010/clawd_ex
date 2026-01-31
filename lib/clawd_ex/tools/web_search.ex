defmodule ClawdEx.Tools.WebSearch do
  @moduledoc """
  Web 搜索工具 - Brave Search API 集成

  使用 Brave Search API 进行网络搜索，返回结构化的搜索结果。
  支持区域/语言设置和时间过滤。
  """
  @behaviour ClawdEx.Tools.Tool

  require Logger

  @brave_api_url "https://api.search.brave.com/res/v1/web/search"
  @default_timeout 30_000
  @default_max_results 5
  # 15 minutes
  @cache_ttl_ms 15 * 60 * 1000

  # 简单内存缓存 (生产中应使用 ETS 或 Cachex)
  use Agent

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  @impl true
  def name, do: "web_search"

  @impl true
  def description do
    "Search the web using Brave Search API. Returns titles, URLs, and snippets for fast research. Supports region-specific and localized search via country and language parameters."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        query: %{
          type: "string",
          description: "Search query string."
        },
        count: %{
          type: "integer",
          description: "Number of results to return (1-10)."
        },
        country: %{
          type: "string",
          description:
            "2-letter country code for region-specific results (e.g., 'DE', 'US', 'ALL'). Default: 'US'."
        },
        search_lang: %{
          type: "string",
          description: "ISO language code for search results (e.g., 'de', 'en', 'fr')."
        },
        ui_lang: %{
          type: "string",
          description: "ISO language code for UI elements."
        },
        freshness: %{
          type: "string",
          description:
            "Filter results by discovery time. Values: 'pd' (past 24h), 'pw' (past week), 'pm' (past month), 'py' (past year), or date range 'YYYY-MM-DDtoYYYY-MM-DD'."
        }
      },
      required: ["query"]
    }
  end

  @impl true
  def execute(params, _context) do
    query = params["query"] || params[:query]
    count = min(params["count"] || params[:count] || @default_max_results, 10)
    country = params["country"] || params[:country]
    search_lang = params["search_lang"] || params[:search_lang]
    ui_lang = params["ui_lang"] || params[:ui_lang]
    freshness = params["freshness"] || params[:freshness]

    api_key = get_api_key()

    if is_nil(api_key) or api_key == "" do
      {:error,
       """
       Brave Search API key not configured.

       Set BRAVE_API_KEY environment variable or configure in config:
         config :clawd_ex, :tools,
           web: [search: [api_key: "YOUR_API_KEY"]]

       Get a free API key at: https://brave.com/search/api/
       """}
    else
      # 检查缓存
      cache_key = build_cache_key(query, count, country, search_lang, freshness)

      case get_cached(cache_key) do
        {:ok, cached_result} ->
          Logger.debug("Returning cached search results for: #{query}")
          {:ok, cached_result}

        :miss ->
          do_search(api_key, query, count, country, search_lang, ui_lang, freshness, cache_key)
      end
    end
  end

  defp do_search(api_key, query, count, country, search_lang, ui_lang, freshness, cache_key) do
    # 构建查询参数
    query_params =
      %{q: query, count: count}
      |> maybe_add(:country, country)
      |> maybe_add(:search_lang, search_lang)
      |> maybe_add(:ui_lang, ui_lang)
      |> maybe_add(:freshness, freshness)

    headers = [
      {"Accept", "application/json"},
      {"Accept-Encoding", "gzip"},
      {"X-Subscription-Token", api_key}
    ]

    Logger.debug("Brave Search query: #{query}, params: #{inspect(query_params)}")

    case Req.get(@brave_api_url,
           params: query_params,
           headers: headers,
           receive_timeout: @default_timeout
         ) do
      {:ok, %{status: 200, body: body}} ->
        result = format_results(body)
        cache_result(cache_key, result)
        {:ok, result}

      {:ok, %{status: 401}} ->
        {:error, "Invalid Brave API key. Check your BRAVE_API_KEY."}

      {:ok, %{status: 429}} ->
        {:error, "Brave API rate limit exceeded. Please try again later."}

      {:ok, %{status: status, body: body}} ->
        {:error, "Brave API error (#{status}): #{inspect(body)}"}

      {:error, reason} ->
        {:error, "Search request failed: #{inspect(reason)}"}
    end
  end

  defp format_results(body) do
    web_results = get_in(body, ["web", "results"]) || []

    results =
      Enum.map(web_results, fn result ->
        %{
          title: result["title"],
          url: result["url"],
          description: result["description"],
          age: result["age"]
        }
      end)

    query_info = body["query"] || %{}

    %{
      query: query_info["original"] || query_info["altered"] || "",
      results: results,
      result_count: length(results)
    }
  end

  defp get_api_key do
    # 优先从环境变量读取，其次从配置
    System.get_env("BRAVE_API_KEY") ||
      get_in(Application.get_env(:clawd_ex, :tools, []), [:web, :search, :api_key])
  end

  defp maybe_add(map, _key, nil), do: map
  defp maybe_add(map, _key, ""), do: map
  defp maybe_add(map, key, value), do: Map.put(map, key, value)

  defp build_cache_key(query, count, country, search_lang, freshness) do
    :crypto.hash(:sha256, "#{query}|#{count}|#{country}|#{search_lang}|#{freshness}")
    |> Base.encode16(case: :lower)
  end

  defp get_cached(key) do
    try do
      case Agent.get(__MODULE__, &Map.get(&1, key)) do
        nil ->
          :miss

        {result, timestamp} ->
          if System.monotonic_time(:millisecond) - timestamp < @cache_ttl_ms do
            {:ok, result}
          else
            :miss
          end
      end
    catch
      :exit, _ -> :miss
    end
  end

  defp cache_result(key, result) do
    try do
      timestamp = System.monotonic_time(:millisecond)
      Agent.update(__MODULE__, &Map.put(&1, key, {result, timestamp}))
    catch
      :exit, _ -> :ok
    end
  end
end
