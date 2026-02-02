defmodule ClawdEx.AI.Vision do
  @moduledoc """
  Vision API 模块

  支持多个提供商的图像分析:
  - Anthropic Claude (claude-3-* 系列)
  - OpenAI GPT-4 Vision
  - Google Gemini Pro Vision
  """

  require Logger

  alias ClawdEx.AI.Models

  @type image_source :: {:url, String.t()} | {:base64, String.t(), String.t()}
  @type analysis_result :: {:ok, String.t()} | {:error, term()}

  @default_max_bytes 20 * 1024 * 1024  # 20MB
  @default_timeout_ms 60_000

  @doc """
  分析图片

  ## 参数
  - image: 图片 URL 或 base64 data URL
  - prompt: 分析提示 (可选)
  - opts: 选项
    - model: 模型覆盖
    - max_bytes: 最大图片大小
    - timeout_ms: 超时时间
  """
  @spec analyze(String.t(), String.t() | nil, keyword()) :: analysis_result()
  def analyze(image, prompt \\ nil, opts \\ []) do
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)
    model = Keyword.get(opts, :model)

    with {:ok, image_source} <- parse_image_input(image, max_bytes),
         {:ok, provider, model_name} <- resolve_vision_model(model) do
      prompt = prompt || "Describe this image in detail."

      case provider do
        :anthropic -> analyze_anthropic(image_source, prompt, model_name, opts)
        :openai -> analyze_openai(image_source, prompt, model_name, opts)
        :google -> analyze_google(image_source, prompt, model_name, opts)
      end
    end
  end

  @doc """
  解析 base64 data URL
  """
  @spec decode_data_url(String.t()) :: {:ok, {binary(), String.t()}} | {:error, String.t()}
  def decode_data_url(data_url) do
    trimmed = String.trim(data_url)

    case Regex.run(~r/^data:([^;,]+);base64,([a-zA-Z0-9+\/=\r\n]+)$/i, trimmed) do
      [_, mime_type, b64_data] ->
        mime = String.downcase(String.trim(mime_type))

        if String.starts_with?(mime, "image/") do
          case Base.decode64(String.replace(b64_data, ~r/[\r\n]/, "")) do
            {:ok, binary} when byte_size(binary) > 0 ->
              {:ok, {binary, mime}}

            {:ok, _} ->
              {:error, "Invalid data URL: empty payload"}

            :error ->
              {:error, "Invalid base64 encoding"}
          end
        else
          {:error, "Unsupported data URL type: #{mime}"}
        end

      nil ->
        {:error, "Invalid data URL format"}
    end
  end

  # ============================================================================
  # Private - 输入解析
  # ============================================================================

  defp parse_image_input(image, max_bytes) do
    cond do
      String.starts_with?(image, "data:") ->
        parse_data_url(image, max_bytes)

      String.starts_with?(image, "http://") or String.starts_with?(image, "https://") ->
        {:ok, {:url, image}}

      true ->
        {:error, "Invalid image input: expected URL or base64 data URL"}
    end
  end

  defp parse_data_url(data_url, max_bytes) do
    case decode_data_url(data_url) do
      {:ok, {binary, mime_type}} ->
        if byte_size(binary) <= max_bytes do
          b64 = Base.encode64(binary)
          {:ok, {:base64, b64, mime_type}}
        else
          {:error, "Image too large: #{byte_size(binary)} bytes (max: #{max_bytes})"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ============================================================================
  # Private - 模型解析
  # ============================================================================

  defp resolve_vision_model(nil) do
    # 使用默认视觉模型
    model = Models.default_vision()
    {provider, model_name} = Models.parse(model)
    {:ok, provider, model_name}
  end

  defp resolve_vision_model(model) when is_binary(model) do
    resolved = Models.resolve(model)

    if Models.has_capability?(resolved, :vision) do
      {provider, model_name} = Models.parse(resolved)
      {:ok, provider, model_name}
    else
      {:error, "Model #{model} does not support vision"}
    end
  end

  # ============================================================================
  # Private - Anthropic Vision
  # ============================================================================

  defp analyze_anthropic(image_source, prompt, model, opts) do
    alias ClawdEx.AI.OAuth

    case OAuth.get_api_key(:anthropic) do
      {:ok, api_key} ->
        timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
        is_oauth = OAuth.oauth_token?(api_key)

        content = build_anthropic_content(image_source, prompt)

        body = %{
          model: model,
          max_tokens: 4096,
          messages: [%{role: "user", content: content}]
        }

        body = if is_oauth do
          Map.put(body, :system, ClawdEx.AI.OAuth.Anthropic.build_system_prompt(nil))
        else
          body
        end

        headers = anthropic_headers(api_key)

        case Req.post("https://api.anthropic.com/v1/messages",
               json: body,
               headers: headers,
               receive_timeout: timeout
             ) do
          {:ok, %{status: 200, body: %{"content" => [%{"text" => text} | _]}}} ->
            {:ok, text}

          {:ok, %{status: status, body: body}} ->
            {:error, {:api_error, status, body}}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_anthropic_content({:url, url}, prompt) do
    [
      %{type: "image", source: %{type: "url", url: url}},
      %{type: "text", text: prompt}
    ]
  end

  defp build_anthropic_content({:base64, data, media_type}, prompt) do
    [
      %{type: "image", source: %{type: "base64", media_type: media_type, data: data}},
      %{type: "text", text: prompt}
    ]
  end

  defp anthropic_headers(api_key) do
    base = [
      {"x-api-key", api_key},
      {"anthropic-version", "2023-06-01"},
      {"content-type", "application/json"}
    ]

    if ClawdEx.AI.OAuth.oauth_token?(api_key) do
      ClawdEx.AI.OAuth.Anthropic.api_headers(api_key)
    else
      base
    end
  end

  # ============================================================================
  # Private - OpenAI Vision
  # ============================================================================

  defp analyze_openai(image_source, prompt, model, opts) do
    api_key = System.get_env("OPENAI_API_KEY")

    if is_nil(api_key) do
      {:error, :missing_api_key}
    else
      timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
      content = build_openai_content(image_source, prompt)

      body = %{
        model: model,
        messages: [%{role: "user", content: content}],
        max_tokens: 4096
      }

      case Req.post("https://api.openai.com/v1/chat/completions",
             json: body,
             headers: [
               {"authorization", "Bearer #{api_key}"},
               {"content-type", "application/json"}
             ],
             receive_timeout: timeout
           ) do
        {:ok, %{status: 200, body: %{"choices" => [%{"message" => %{"content" => text}} | _]}}} ->
          {:ok, text}

        {:ok, %{status: status, body: body}} ->
          {:error, {:api_error, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp build_openai_content({:url, url}, prompt) do
    [
      %{type: "text", text: prompt},
      %{type: "image_url", image_url: %{url: url}}
    ]
  end

  defp build_openai_content({:base64, data, media_type}, prompt) do
    [
      %{type: "text", text: prompt},
      %{type: "image_url", image_url: %{url: "data:#{media_type};base64,#{data}"}}
    ]
  end

  # ============================================================================
  # Private - Google Vision
  # ============================================================================

  defp analyze_google(image_source, prompt, model, opts) do
    api_key = System.get_env("GEMINI_API_KEY")

    if is_nil(api_key) do
      {:error, :missing_api_key}
    else
      timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
      parts = build_google_parts(image_source, prompt)

      body = %{
        contents: [%{parts: parts}],
        generationConfig: %{maxOutputTokens: 4096}
      }

      url = "https://generativelanguage.googleapis.com/v1beta/models/#{model}:generateContent?key=#{api_key}"

      case Req.post(url,
             json: body,
             headers: [{"content-type", "application/json"}],
             receive_timeout: timeout
           ) do
        {:ok, %{status: 200, body: %{"candidates" => [%{"content" => %{"parts" => [%{"text" => text} | _]}} | _]}}} ->
          {:ok, text}

        {:ok, %{status: status, body: body}} ->
          {:error, {:api_error, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp build_google_parts({:url, url}, prompt) do
    # Google 需要下载 URL 图片然后转为 base64
    # 简化处理：直接使用 inline_data
    case Req.get(url, receive_timeout: 30_000) do
      {:ok, %{status: 200, body: binary, headers: headers}} ->
        content_type = get_content_type(headers) || "image/jpeg"
        b64 = Base.encode64(binary)
        [
          %{text: prompt},
          %{inline_data: %{mime_type: content_type, data: b64}}
        ]

      _ ->
        # 回退到仅文本
        [%{text: "#{prompt} (Image URL: #{url})"}]
    end
  end

  defp build_google_parts({:base64, data, media_type}, prompt) do
    [
      %{text: prompt},
      %{inline_data: %{mime_type: media_type, data: data}}
    ]
  end

  defp get_content_type(headers) do
    headers
    |> Enum.find(fn {k, _v} -> String.downcase(k) == "content-type" end)
    |> case do
      {_, v} -> v
      nil -> nil
    end
  end
end
