defmodule ClawdExWeb.ContentRenderer do
  @moduledoc """
  渲染消息内容，支持完整的 Markdown 和多媒体展示

  Features:
  - Markdown 渲染 (使用 MDEx)
  - 代码语法高亮 (内置主题)
  - 图片展示 (支持点击放大)
  - 视频播放 (mp4, webm, ogg)
  - 音频播放 (mp3, wav, ogg)
  - 文件下载链接
  - MEDIA: 标签解析
  """

  import Phoenix.HTML, only: [raw: 1]

  # 支持的媒体扩展名
  @image_extensions ~w(.jpg .jpeg .png .gif .webp .svg .bmp .ico)
  @video_extensions ~w(.mp4 .webm .ogg .mov .avi .mkv)
  @audio_extensions ~w(.mp3 .wav .ogg .m4a .aac .flac)

  # 预编译正则表达式（在模块编译时）避免 Elixir 1.19 语法问题
  @external_link_pattern Regex.compile!("<a\\s+href=\"(https?://[^\"]+)\"([^>]*)>([^<]+)</a>")

  @doc """
  将消息内容渲染为 HTML

  ## Examples

      iex> ContentRenderer.render_content("**Hello** World")
      {:safe, "<p><strong>Hello</strong> World</p>"}

      iex> ContentRenderer.render_content("MEDIA: /path/to/image.png")
      {:safe, "<div class=\"media-block\">...</div>"}
  """
  def render_content(content) when is_binary(content) do
    content
    |> preprocess_media_tags()
    |> render_markdown()
    |> postprocess_html()
    |> raw()
  end

  def render_content(nil), do: raw("")
  def render_content(other), do: render_content(to_string(other))

  # ============================================================================
  # 预处理：解析 MEDIA: 标签
  # ============================================================================

  # 预处理 MEDIA: 标签，将其转换为 Markdown 格式或 HTML
  # 支持格式：
  # - MEDIA: /path/to/file.png
  # - MEDIA: /path/to/video.mp4
  # - MEDIA: /path/to/audio.mp3
  defp preprocess_media_tags(content) do
    # 匹配 MEDIA: 开头的行
    Regex.replace(~r/^MEDIA:\s*(.+)$/m, content, fn _, path ->
      path = String.trim(path)
      render_media_tag(path)
    end)
  end

  defp render_media_tag(path) do
    ext = Path.extname(path) |> String.downcase()
    url = resolve_media_url(path)

    cond do
      ext in @image_extensions ->
        # 图片使用 Markdown 语法，让 MDEx 处理
        "![image](#{url})"

      ext in @video_extensions ->
        # 视频使用 HTML（MDEx 会保留原始 HTML）
        """
        <div class="media-block my-2">
          <video controls class="max-w-full rounded-lg shadow-md" preload="metadata">
            <source src="#{escape_attr(url)}" type="#{video_mime_type(ext)}">
            Your browser does not support video playback.
          </video>
        </div>
        """

      ext in @audio_extensions ->
        # 音频使用 HTML
        """
        <div class="media-block my-2">
          <audio controls class="w-full" preload="metadata">
            <source src="#{escape_attr(url)}" type="#{audio_mime_type(ext)}">
            Your browser does not support audio playback.
          </audio>
        </div>
        """

      true ->
        # 其他文件类型，显示为下载链接
        filename = Path.basename(path)

        """
        <div class="media-block my-2">
          <a href="#{escape_attr(url)}" download class="inline-flex items-center gap-2 px-3 py-2 bg-gray-700 hover:bg-gray-600 rounded-lg text-blue-400 transition-colors">
            <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 10v6m0 0l-3-3m3 3l3-3m2 8H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z"/>
            </svg>
            <span>#{escape_html(filename)}</span>
          </a>
        </div>
        """
    end
  end

  # ============================================================================
  # Markdown 渲染
  # ============================================================================

  defp render_markdown(content) do
    # MDEx 选项
    opts = [
      extension: [
        strikethrough: true,
        table: true,
        autolink: true,
        tasklist: true,
        superscript: true,
        footnotes: true,
        description_lists: true,
        shortcodes: true
      ],
      parse: [
        smart: true,
        relaxed_autolinks: true
      ],
      render: [
        github_pre_lang: true,
        escape: false,
        unsafe_: true
      ],
      syntax_highlight: [
        formatter: {:html_inline, theme: "onedark"}
      ]
    ]

    case MDEx.to_html(content, opts) do
      {:ok, html} -> html
      {:error, _reason} -> fallback_render(content)
    end
  end

  # 降级渲染（MDEx 失败时）
  defp fallback_render(content) do
    content
    |> escape_html()
    |> String.replace("\n", "<br/>")
  end

  # ============================================================================
  # 后处理：增强 HTML
  # ============================================================================

  defp postprocess_html(html) do
    html
    |> enhance_images()
    |> enhance_links()
    |> enhance_code_blocks()
  end

  # 增强图片：添加点击放大、懒加载
  defp enhance_images(html) do
    # 匹配 img 标签，包括自闭合的情况
    Regex.replace(
      ~r/<img\s+([^>]*?)(?:\s*\/)?>/,
      html,
      fn full_match, attrs ->
        # 检查是否已经有我们的类
        if String.contains?(attrs, "media-image") do
          full_match
        else
          # 移除末尾的 / 并添加我们的属性
          attrs = String.trim_trailing(attrs, "/") |> String.trim()
          # 使用 [] 作为定界符避免括号问题
          ~s[<img #{attrs} class="media-image max-w-full max-h-96 rounded-lg shadow-sm cursor-pointer hover:shadow-lg transition-all" onclick="window.open(this.src, '_blank')" loading="lazy" />]
        end
      end
    )
  end

  # 增强链接：添加外部链接图标
  defp enhance_links(html) do
    # 匹配外部 http/https 链接（使用预编译的模块属性）
    Regex.replace(
      @external_link_pattern,
      html,
      fn _, href, attrs, text ->
        # 检查是否已经有 target
        attrs =
          if String.contains?(attrs, "target="),
            do: attrs,
            else: attrs <> ~s[ target="_blank" rel="noopener noreferrer"]

        # 使用 [] 定界符避免括号问题
        ~s[<a href="#{href}"#{attrs} class="text-blue-400 hover:text-blue-300 hover:underline inline-flex items-center gap-1">#{text}<svg class="w-3 h-3 inline" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10 6H6a2 2 0 00-2 2v10a2 2 0 002 2h10a2 2 0 002-2v-4M14 4h6m0 0v6m0-6L10 14"/></svg></a>]
      end
    )
  end

  # 增强代码块：添加复制按钮
  defp enhance_code_blocks(html) do
    # 为 pre 标签添加包装和复制按钮
    Regex.replace(
      ~r/<pre([^>]*)><code([^>]*)>([\s\S]*?)<\/code><\/pre>/,
      html,
      fn _, pre_attrs, code_attrs, code_content ->
        # 提取语言
        lang =
          case Regex.run(~r/class="[^"]*language-(\w+)[^"]*"/, code_attrs) do
            [_, language] -> language
            _ -> ""
          end

        lang_badge =
          if lang != "",
            do:
              "<span class=\"absolute top-2 right-12 text-xs text-gray-400 font-mono\">#{escape_html(lang)}</span>",
            else: ""

        """
        <div class="code-block-wrapper relative my-3 group">
          #{lang_badge}
          <button onclick="navigator.clipboard.writeText(this.parentElement.querySelector('code').textContent)" class="absolute top-2 right-2 p-1.5 rounded bg-gray-600 hover:bg-gray-500 text-gray-300 opacity-0 group-hover:opacity-100 transition-opacity" title="Copy code">
            <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M8 16H6a2 2 0 01-2-2V6a2 2 0 012-2h8a2 2 0 012 2v2m-6 12h8a2 2 0 002-2v-8a2 2 0 00-2-2h-8a2 2 0 00-2 2v8a2 2 0 002 2z"/>
            </svg>
          </button>
          <pre#{pre_attrs} class="rounded-lg overflow-x-auto"><code#{code_attrs}>#{code_content}</code></pre>
        </div>
        """
      end
    )
  end

  # ============================================================================
  # 辅助函数
  # ============================================================================

  # 解析媒体路径，转换为可访问的 URL
  defp resolve_media_url(path) do
    cond do
      # 已经是完整 URL
      String.starts_with?(path, "http://") or String.starts_with?(path, "https://") ->
        path

      # data: URL
      String.starts_with?(path, "data:") ->
        path

      # 截图路径
      String.contains?(path, "screenshots/") ->
        filename = Path.basename(path)
        "/media/screenshots/#{filename}"

      # TTS 输出
      String.contains?(path, "tts/") ->
        filename = Path.basename(path)
        "/media/tts/#{filename}"

      # 通用本地路径
      true ->
        "/media/files/#{Path.basename(path)}"
    end
  end

  defp video_mime_type(ext) do
    case ext do
      ".mp4" -> "video/mp4"
      ".webm" -> "video/webm"
      ".ogg" -> "video/ogg"
      ".mov" -> "video/quicktime"
      _ -> "video/mp4"
    end
  end

  defp audio_mime_type(ext) do
    case ext do
      ".mp3" -> "audio/mpeg"
      ".wav" -> "audio/wav"
      ".ogg" -> "audio/ogg"
      ".m4a" -> "audio/mp4"
      ".aac" -> "audio/aac"
      ".flac" -> "audio/flac"
      _ -> "audio/mpeg"
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

  defp escape_attr(text) do
    text
    |> to_string()
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end
end
