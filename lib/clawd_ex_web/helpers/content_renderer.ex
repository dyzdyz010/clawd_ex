defmodule ClawdExWeb.ContentRenderer do
  @moduledoc """
  渲染消息内容，处理 Markdown 图片、链接、代码等
  """

  import Phoenix.HTML, only: [raw: 1]

  @doc """
  将消息内容渲染为 HTML
  """
  def render_content(content) when is_binary(content) do
    content
    |> parse_and_render()
    |> raw()
  end

  def render_content(nil), do: raw("")
  def render_content(other), do: render_content(to_string(other))

  # 解析并渲染内容
  defp parse_and_render(content) do
    content
    # 先处理代码块（保护其中的内容）
    |> extract_and_render_code_blocks()
    # 然后处理其他 Markdown
    |> render_images()
    |> render_links()
    |> render_bold()
    |> render_inline_code()
    # 最后处理换行
    |> String.replace("\n", "<br/>")
  end

  # 渲染代码块 ```lang\ncode\n```
  defp extract_and_render_code_blocks(content) do
    Regex.replace(
      ~r/```(\w*)\n(.*?)```/s,
      content,
      fn _, lang, code ->
        escaped_code = escape_html(code)
        lang_label = if lang != "", do: "<span class=\"text-xs text-gray-400\">#{escape_html(lang)}</span>", else: ""
        """
        <div class="my-2 bg-gray-800 rounded-lg overflow-hidden">
          #{lang_label}
          <pre class="p-3 text-sm text-gray-100 overflow-x-auto whitespace-pre"><code>#{escaped_code}</code></pre>
        </div>
        """
      end
    )
  end

  # 渲染 Markdown 图片 ![alt](path)
  defp render_images(content) do
    Regex.replace(
      ~r/!\[([^\]]*)\]\(([^)]+)\)/,
      content,
      fn _, alt, path ->
        url = resolve_image_url(path)
        escaped_url = escape_html(url)
        escaped_alt = escape_html(alt)
        alt_div = if alt != "", do: "<div class=\"text-xs text-gray-500 mt-1\">#{escaped_alt}</div>", else: ""
        """
        <div class="my-2">
          <img src="#{escaped_url}" alt="#{escaped_alt}" class="max-w-full max-h-96 rounded-lg shadow-sm cursor-pointer hover:shadow-md transition-shadow" onclick="window.open(this.src, '_blank')" loading="lazy" />
          #{alt_div}
        </div>
        """
      end
    )
  end

  # 渲染链接 [text](url)
  defp render_links(content) do
    Regex.replace(
      ~r/(?<!!)\[([^\]]+)\]\(([^)]+)\)/,
      content,
      fn _, text, url ->
        "<a href=\"#{escape_html(url)}\" target=\"_blank\" rel=\"noopener\" class=\"text-indigo-600 hover:underline\">#{escape_html(text)}</a>"
      end
    )
  end

  # 渲染粗体 **text**
  defp render_bold(content) do
    Regex.replace(
      ~r/\*\*([^*]+)\*\*/,
      content,
      fn _, text ->
        "<strong>#{escape_html(text)}</strong>"
      end
    )
  end

  # 渲染行内代码 `code`
  defp render_inline_code(content) do
    Regex.replace(
      ~r/`([^`]+)`/,
      content,
      fn _, code ->
        "<code class=\"bg-gray-200 text-pink-600 px-1 py-0.5 rounded text-sm font-mono\">#{escape_html(code)}</code>"
      end
    )
  end

  # 解析图片路径，转换为可访问的 URL
  defp resolve_image_url(path) do
    cond do
      # 已经是 URL
      String.starts_with?(path, "http://") or String.starts_with?(path, "https://") ->
        path

      # 截图路径 - 提取文件名
      String.contains?(path, "screenshots/") ->
        filename = Path.basename(path)
        "/media/screenshots/#{filename}"

      # data: URL
      String.starts_with?(path, "data:") ->
        path

      # 其他本地路径
      true ->
        "/media/files/#{Path.basename(path)}"
    end
  end

  defp escape_html(text) do
    text
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
