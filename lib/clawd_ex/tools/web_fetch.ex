defmodule ClawdEx.Tools.WebFetch do
  @moduledoc """
  URL 抓取工具 - HTTP 获取 + HTML 转 Markdown

  获取 URL 内容并提取可读内容，将 HTML 转换为 Markdown 或纯文本格式。
  不执行 JavaScript，适用于静态内容抓取。
  """
  @behaviour ClawdEx.Tools.Tool

  require Logger

  @default_user_agent "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_7_2) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"
  @default_timeout 30_000
  @default_max_chars 50_000
  @default_max_redirects 3
  # 15 minutes
  @cache_ttl_ms 15 * 60 * 1000

  # 简单内存缓存
  use Agent

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  @impl true
  def name, do: "web_fetch"

  @impl true
  def description do
    "Fetch and extract readable content from a URL (HTML → markdown/text). Use for lightweight page access without browser automation. Does not execute JavaScript."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        url: %{
          type: "string",
          description: "HTTP or HTTPS URL to fetch."
        },
        extractMode: %{
          type: "string",
          enum: ["markdown", "text"],
          description: "Extraction mode ('markdown' or 'text'). Default: 'markdown'."
        },
        maxChars: %{
          type: "integer",
          description: "Maximum characters to return (truncates when exceeded)."
        }
      },
      required: ["url"]
    }
  end

  @impl true
  def execute(params, _context) do
    url = params["url"] || params[:url]
    extract_mode = params["extractMode"] || params[:extractMode] || "markdown"
    max_chars = params["maxChars"] || params[:maxChars] || @default_max_chars

    # 验证 URL
    case validate_url(url) do
      {:error, reason} ->
        {:error, reason}

      :ok ->
        # 检查缓存
        cache_key = build_cache_key(url, extract_mode)

        case get_cached(cache_key) do
          {:ok, cached_result} ->
            Logger.debug("Returning cached fetch result for: #{url}")
            {:ok, truncate_result(cached_result, max_chars)}

          :miss ->
            do_fetch(url, extract_mode, max_chars, cache_key)
        end
    end
  end

  defp do_fetch(url, extract_mode, max_chars, cache_key) do
    headers = [
      {"User-Agent", @default_user_agent},
      {"Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"},
      {"Accept-Language", "en-US,en;q=0.9"},
      {"Accept-Encoding", "gzip, deflate"}
    ]

    Logger.debug("Fetching URL: #{url}")

    case Req.get(url,
           headers: headers,
           receive_timeout: @default_timeout,
           max_redirects: @default_max_redirects,
           redirect: true
         ) do
      {:ok, %{status: status, body: body, headers: resp_headers}} when status in 200..299 ->
        content_type = get_content_type(resp_headers)
        result = extract_content(body, content_type, extract_mode)
        cache_result(cache_key, result)
        {:ok, truncate_result(result, max_chars)}

      {:ok, %{status: status}} when status in [301, 302, 303, 307, 308] ->
        {:error, "Too many redirects (max: #{@default_max_redirects})"}

      {:ok, %{status: 403}} ->
        {:error, "Access forbidden (403). The site may be blocking automated requests."}

      {:ok, %{status: 404}} ->
        {:error, "Page not found (404): #{url}"}

      {:ok, %{status: status}} ->
        {:error, "HTTP error #{status} fetching #{url}"}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, "Request timed out fetching #{url}"}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, "Network error: #{inspect(reason)}"}

      {:error, reason} ->
        {:error, "Failed to fetch URL: #{inspect(reason)}"}
    end
  end

  defp validate_url(url) do
    uri = URI.parse(url)

    cond do
      uri.scheme not in ["http", "https"] ->
        {:error, "Only HTTP and HTTPS URLs are supported"}

      is_nil(uri.host) or uri.host == "" ->
        {:error, "Invalid URL: missing host"}

      private_host?(uri.host) ->
        {:error, "Cannot fetch private/internal hosts"}

      true ->
        :ok
    end
  end

  defp private_host?(host) do
    # 检查是否为私有/内部主机
    host = String.downcase(host)

    cond do
      host == "localhost" -> true
      host == "127.0.0.1" -> true
      String.starts_with?(host, "192.168.") -> true
      String.starts_with?(host, "10.") -> true
      String.starts_with?(host, "172.16.") -> true
      String.match?(host, ~r/^172\.(1[6-9]|2[0-9]|3[0-1])\./) -> true
      host == "::1" -> true
      String.ends_with?(host, ".local") -> true
      String.ends_with?(host, ".internal") -> true
      true -> false
    end
  end

  defp get_content_type(headers) do
    headers
    |> Enum.find(fn {key, _} -> String.downcase(key) == "content-type" end)
    |> case do
      {_, value} -> value
      nil -> "text/html"
    end
  end

  defp extract_content(body, content_type, extract_mode) when is_binary(body) do
    # Ensure content_type is a string
    ct = to_string(content_type || "text/html")
    
    cond do
      String.contains?(ct, "text/html") or
          String.contains?(ct, "application/xhtml") ->
        html_to_readable(body, extract_mode)

      String.contains?(ct, "text/plain") ->
        body

      String.contains?(ct, "application/json") ->
        body

      String.contains?(ct, "text/") ->
        body

      true ->
        "[Binary content: #{ct}]"
    end
  end

  defp extract_content(_body, content_type, _extract_mode) do
    "[Unsupported content type: #{content_type}]"
  end

  defp html_to_readable(html, extract_mode) do
    # 简单的 HTML 清理和转换
    # 1. 移除 script, style, nav, footer 等非内容元素
    # 2. 提取主要内容
    # 3. 转换为 markdown 或纯文本

    html
    |> remove_unwanted_elements()
    |> extract_main_content()
    |> convert_to_format(extract_mode)
    |> clean_whitespace()
  end

  defp remove_unwanted_elements(html) do
    # 移除 script, style, nav, header, footer, aside, form 等
    html
    |> String.replace(~r/<script[^>]*>.*?<\/script>/is, "")
    |> String.replace(~r/<style[^>]*>.*?<\/style>/is, "")
    |> String.replace(~r/<nav[^>]*>.*?<\/nav>/is, "")
    |> String.replace(~r/<header[^>]*>.*?<\/header>/is, "")
    |> String.replace(~r/<footer[^>]*>.*?<\/footer>/is, "")
    |> String.replace(~r/<aside[^>]*>.*?<\/aside>/is, "")
    |> String.replace(~r/<form[^>]*>.*?<\/form>/is, "")
    |> String.replace(~r/<noscript[^>]*>.*?<\/noscript>/is, "")
    |> String.replace(~r/<iframe[^>]*>.*?<\/iframe>/is, "")
    |> String.replace(~r/<!--.*?-->/s, "")
  end

  defp extract_main_content(html) do
    # 尝试提取 main, article, 或 body 内容
    cond do
      match = Regex.run(~r/<main[^>]*>(.*?)<\/main>/is, html) ->
        Enum.at(match, 1) || html

      match = Regex.run(~r/<article[^>]*>(.*?)<\/article>/is, html) ->
        Enum.at(match, 1) || html

      match =
          Regex.run(
            ~r/<div[^>]*(?:class|id)=[^>]*(?:content|main|article)[^>]*>(.*?)<\/div>/is,
            html
          ) ->
        Enum.at(match, 1) || html

      match = Regex.run(~r/<body[^>]*>(.*?)<\/body>/is, html) ->
        Enum.at(match, 1) || html

      true ->
        html
    end
  end

  defp convert_to_format(html, "markdown") do
    html
    # 标题转换
    |> String.replace(~r/<h1[^>]*>(.*?)<\/h1>/is, "\n# \\1\n")
    |> String.replace(~r/<h2[^>]*>(.*?)<\/h2>/is, "\n## \\1\n")
    |> String.replace(~r/<h3[^>]*>(.*?)<\/h3>/is, "\n### \\1\n")
    |> String.replace(~r/<h4[^>]*>(.*?)<\/h4>/is, "\n#### \\1\n")
    |> String.replace(~r/<h5[^>]*>(.*?)<\/h5>/is, "\n##### \\1\n")
    |> String.replace(~r/<h6[^>]*>(.*?)<\/h6>/is, "\n###### \\1\n")
    # 段落
    |> String.replace(~r/<p[^>]*>(.*?)<\/p>/is, "\n\\1\n")
    # 链接
    |> String.replace(~r/<a[^>]*href=["']([^"']+)["'][^>]*>(.*?)<\/a>/is, "[\\2](\\1)")
    # 强调
    |> String.replace(~r/<strong[^>]*>(.*?)<\/strong>/is, "**\\1**")
    |> String.replace(~r/<b[^>]*>(.*?)<\/b>/is, "**\\1**")
    |> String.replace(~r/<em[^>]*>(.*?)<\/em>/is, "*\\1*")
    |> String.replace(~r/<i[^>]*>(.*?)<\/i>/is, "*\\1*")
    # 代码
    |> String.replace(~r/<code[^>]*>(.*?)<\/code>/is, "`\\1`")
    |> String.replace(~r/<pre[^>]*>(.*?)<\/pre>/is, "\n```\n\\1\n```\n")
    # 列表
    |> String.replace(~r/<li[^>]*>(.*?)<\/li>/is, "\n- \\1")
    |> String.replace(~r/<ul[^>]*>(.*?)<\/ul>/is, "\\1\n")
    |> String.replace(~r/<ol[^>]*>(.*?)<\/ol>/is, "\\1\n")
    # 换行
    |> String.replace(~r/<br\s*\/?>/i, "\n")
    |> String.replace(~r/<hr\s*\/?>/i, "\n---\n")
    # 引用块
    |> String.replace(~r/<blockquote[^>]*>(.*?)<\/blockquote>/is, "\n> \\1\n")
    # 图片
    |> String.replace(~r/<img[^>]*alt=["']([^"']+)["'][^>]*>/i, "[Image: \\1]")
    |> String.replace(~r/<img[^>]*src=["']([^"']+)["'][^>]*>/i, "[Image: \\1]")
    # 移除剩余标签
    |> String.replace(~r/<[^>]+>/, "")
    # HTML 实体解码
    |> decode_html_entities()
  end

  defp convert_to_format(html, "text") do
    html
    # 标题添加换行
    |> String.replace(~r/<h[1-6][^>]*>(.*?)<\/h[1-6]>/is, "\n\\1\n")
    # 段落
    |> String.replace(~r/<p[^>]*>(.*?)<\/p>/is, "\n\\1\n")
    # 列表项
    |> String.replace(~r/<li[^>]*>(.*?)<\/li>/is, "\n• \\1")
    # 换行
    |> String.replace(~r/<br\s*\/?>/i, "\n")
    |> String.replace(~r/<hr\s*\/?>/i, "\n---\n")
    # 移除所有标签
    |> String.replace(~r/<[^>]+>/, "")
    # HTML 实体解码
    |> decode_html_entities()
  end

  defp decode_html_entities(text) do
    text
    |> String.replace("&nbsp;", " ")
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&apos;", "'")
    |> String.replace("&mdash;", "—")
    |> String.replace("&ndash;", "–")
    |> String.replace("&hellip;", "…")
    |> String.replace("&copy;", "©")
    |> String.replace("&reg;", "®")
    |> String.replace("&trade;", "™")
    # 处理数字实体
    |> replace_numeric_entities()
    |> replace_hex_entities()
  end

  defp replace_numeric_entities(text) do
    Regex.replace(~r/&#(\d+);/, text, fn _, code ->
      try do
        <<String.to_integer(code)::utf8>>
      rescue
        _ -> ""
      end
    end)
  end

  defp replace_hex_entities(text) do
    Regex.replace(~r/&#x([0-9a-fA-F]+);/, text, fn _, code ->
      try do
        <<String.to_integer(code, 16)::utf8>>
      rescue
        _ -> ""
      end
    end)
  end

  defp clean_whitespace(text) do
    text
    |> String.replace(~r/\r\n/, "\n")
    |> String.replace(~r/[ \t]+/, " ")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end

  defp truncate_result(result, max_chars) when byte_size(result) > max_chars do
    String.slice(result, 0, max_chars) <> "\n\n[Content truncated at #{max_chars} characters]"
  end

  defp truncate_result(result, _max_chars), do: result

  defp build_cache_key(url, extract_mode) do
    :crypto.hash(:sha256, "#{url}|#{extract_mode}")
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
