defmodule ClawdEx.Tools.Image do
  @moduledoc """
  图片分析工具 - Vision API 集成

  使用 AI 视觉模型分析图片内容。
  支持多提供商: Anthropic Claude, OpenAI, Google Gemini
  支持图片输入: URL 或 base64 data URL
  """
  @behaviour ClawdEx.Tools.Tool

  require Logger

  alias ClawdEx.AI.{Models, OAuth}

  @default_timeout 60_000
  @default_max_bytes_mb 20
  @default_prompt "What's in this image? Describe it in detail."

  @impl true
  def name, do: "image"

  @impl true
  def description do
    "Analyze an image with a vision model. Supports image URLs and base64 data URLs. " <>
      "Only use this tool when the image was NOT already provided in the user's message."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        image: %{
          type: "string",
          description: "Image URL or base64 data URL (e.g., data:image/png;base64,...)"
        },
        prompt: %{
          type: "string",
          description: "Question or instruction about the image"
        },
        model: %{
          type: "string",
          description: "Vision model override (e.g., 'anthropic/claude-sonnet-4-20250514', 'openai/gpt-4o')"
        },
        maxBytesMb: %{
          type: "number",
          description: "Maximum image size in MB (default: 20)"
        }
      },
      required: ["image"]
    }
  end

  @impl true
  def execute(params, _context) do
    image_input = params["image"] || params[:image]
    prompt = params["prompt"] || params[:prompt] || @default_prompt
    model_override = params["model"] || params[:model]
    max_bytes_mb = params["maxBytesMb"] || params[:maxBytesMb] || @default_max_bytes_mb

    with {:ok, image_data} <- resolve_image(image_input, max_bytes_mb),
         {:ok, model} <- resolve_model(model_override),
         {:ok, result} <- analyze_image(model, image_data, prompt) do
      {:ok, result}
    end
  end

  # ============================================================================
  # Image Resolution
  # ============================================================================

  defp resolve_image(input, max_bytes_mb) when is_binary(input) do
    cond do
      String.starts_with?(input, "data:") ->
        decode_data_url(input, max_bytes_mb)

      String.starts_with?(input, "http://") or String.starts_with?(input, "https://") ->
        download_image(input, max_bytes_mb)

      true ->
        {:error, "Invalid image input: must be a URL or data URL"}
    end
  end

  defp resolve_image(_, _), do: {:error, "Image parameter is required"}

  defp decode_data_url(data_url, max_bytes_mb) do
    # Pattern: data:image/png;base64,<base64data>
    regex = ~r/^data:([^;,]+);base64,([a-zA-Z0-9+\/=\r\n]+)$/i

    case Regex.run(regex, String.trim(data_url)) do
      [_, mime_type, base64_data] ->
        mime_type = String.downcase(String.trim(mime_type))

        unless String.starts_with?(mime_type, "image/") do
          {:error, "Unsupported data URL type: #{mime_type}"}
        else
          case Base.decode64(String.trim(base64_data), ignore: :whitespace) do
            {:ok, binary} ->
              max_bytes = max_bytes_mb * 1024 * 1024

              if byte_size(binary) > max_bytes do
                {:error, "Image exceeds maximum size of #{max_bytes_mb}MB"}
              else
                {:ok, %{binary: binary, mime_type: mime_type, base64: String.trim(base64_data)}}
              end

            :error ->
              {:error, "Invalid base64 data in data URL"}
          end
        end

      _ ->
        {:error, "Invalid data URL format (expected base64 data: URL)"}
    end
  end

  defp download_image(url, max_bytes_mb) do
    Logger.debug("Downloading image from: #{url}")
    max_bytes = max_bytes_mb * 1024 * 1024

    case Req.get(url,
           receive_timeout: @default_timeout,
           max_redirects: 5,
           decode_body: false
         ) do
      {:ok, %{status: 200, body: body, headers: headers}} ->
        content_type = get_content_type(headers)
        mime_type = normalize_mime_type(content_type)

        cond do
          not String.starts_with?(mime_type, "image/") ->
            {:error, "URL does not point to an image (got: #{content_type})"}

          byte_size(body) > max_bytes ->
            {:error, "Image exceeds maximum size of #{max_bytes_mb}MB"}

          true ->
            base64 = Base.encode64(body)
            {:ok, %{binary: body, mime_type: mime_type, base64: base64}}
        end

      {:ok, %{status: status}} ->
        {:error, "Failed to download image: HTTP #{status}"}

      {:error, reason} ->
        {:error, "Failed to download image: #{inspect(reason)}"}
    end
  end

  defp get_content_type(headers) do
    headers
    |> Enum.find(fn {k, _v} -> String.downcase(k) == "content-type" end)
    |> case do
      {_, v} -> v
      nil -> "application/octet-stream"
    end
  end

  defp normalize_mime_type(content_type) do
    content_type
    |> String.split(";")
    |> List.first()
    |> String.trim()
    |> String.downcase()
  end

  # ============================================================================
  # Model Resolution
  # ============================================================================

  defp resolve_model(nil) do
    # Try vision models in order until we find one with a valid API key
    vision_models = Models.vision_models()

    Enum.reduce_while(vision_models, {:error, "No vision model available"}, fn model, acc ->
      provider = Models.provider(model)

      case check_api_key(provider) do
        :ok -> {:halt, {:ok, model}}
        :error -> {:cont, acc}
      end
    end)
  end

  defp resolve_model(model) when is_binary(model) do
    resolved = Models.resolve(model)
    provider = Models.provider(resolved)

    case check_api_key(provider) do
      :ok -> {:ok, resolved}
      :error -> {:error, "API key not configured for provider: #{provider}"}
    end
  end

  defp parse_model(model) do
    Models.parse(model)
  end

  defp check_api_key(provider) do
    case OAuth.get_api_key(provider) do
      {:ok, key} when is_binary(key) and key != "" -> :ok
      _ -> :error
    end
  end

  # ============================================================================
  # Vision API Calls
  # ============================================================================

  defp analyze_image(model, image_data, prompt) do
    {provider, model_name} = parse_model(model)

    case provider do
      :anthropic -> analyze_anthropic(model_name, image_data, prompt)
      :openai -> analyze_openai(model_name, image_data, prompt)
      :google -> analyze_google(model_name, image_data, prompt)
      _ -> {:error, "Unsupported provider: #{provider}"}
    end
  end

  # Anthropic Claude Vision
  defp analyze_anthropic(model, image_data, prompt) do
    case OAuth.get_api_key(:anthropic) do
      {:ok, api_key} ->
        # Determine media type for Anthropic (they use specific format)
        media_type = image_data.mime_type

        body = %{
          model: model,
          max_tokens: 4096,
          messages: [
            %{
              role: "user",
              content: [
                %{
                  type: "image",
                  source: %{
                    type: "base64",
                    media_type: media_type,
                    data: image_data.base64
                  }
                },
                %{
                  type: "text",
                  text: prompt
                }
              ]
            }
          ]
        }

        headers = build_anthropic_headers(api_key)

        case Req.post("https://api.anthropic.com/v1/messages",
               json: body,
               headers: headers,
               receive_timeout: @default_timeout
             ) do
          {:ok, %{status: 200, body: resp_body}} ->
            extract_anthropic_response(resp_body)

          {:ok, %{status: status, body: error_body}} ->
            {:error, "Anthropic API error (#{status}): #{inspect(error_body)}"}

          {:error, reason} ->
            {:error, "Anthropic request failed: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, "Failed to get Anthropic API key: #{inspect(reason)}"}
    end
  end

  defp build_anthropic_headers(api_key) do
    if OAuth.oauth_token?(api_key) do
      ClawdEx.AI.OAuth.Anthropic.api_headers(api_key)
    else
      [
        {"x-api-key", api_key},
        {"anthropic-version", "2023-06-01"},
        {"content-type", "application/json"}
      ]
    end
  end

  defp extract_anthropic_response(%{"content" => content}) do
    text =
      content
      |> Enum.filter(&(&1["type"] == "text"))
      |> Enum.map(& &1["text"])
      |> Enum.join("")

    if text != "" do
      {:ok, %{analysis: text, provider: "anthropic"}}
    else
      {:error, "Anthropic returned empty response"}
    end
  end

  defp extract_anthropic_response(body) do
    {:error, "Unexpected Anthropic response format: #{inspect(body)}"}
  end

  # OpenAI GPT-4 Vision
  defp analyze_openai(model, image_data, prompt) do
    case OAuth.get_api_key(:openai) do
      {:ok, api_key} ->
        # OpenAI accepts base64 data URL directly
        image_url = "data:#{image_data.mime_type};base64,#{image_data.base64}"

        body = %{
          model: model,
          max_tokens: 4096,
          messages: [
            %{
              role: "user",
              content: [
                %{
                  type: "image_url",
                  image_url: %{url: image_url}
                },
                %{
                  type: "text",
                  text: prompt
                }
              ]
            }
          ]
        }

        case Req.post("https://api.openai.com/v1/chat/completions",
               json: body,
               headers: [
                 {"Authorization", "Bearer #{api_key}"},
                 {"content-type", "application/json"}
               ],
               receive_timeout: @default_timeout
             ) do
          {:ok, %{status: 200, body: resp_body}} ->
            extract_openai_response(resp_body)

          {:ok, %{status: status, body: error_body}} ->
            {:error, "OpenAI API error (#{status}): #{inspect(error_body)}"}

          {:error, reason} ->
            {:error, "OpenAI request failed: #{inspect(reason)}"}
        end

      {:error, _reason} ->
        {:error, "OpenAI API key not configured"}
    end
  end

  defp extract_openai_response(%{"choices" => [%{"message" => %{"content" => content}} | _]}) do
    if content && content != "" do
      {:ok, %{analysis: content, provider: "openai"}}
    else
      {:error, "OpenAI returned empty response"}
    end
  end

  defp extract_openai_response(body) do
    {:error, "Unexpected OpenAI response format: #{inspect(body)}"}
  end

  # Google Gemini Vision
  defp analyze_google(model, image_data, prompt) do
    case OAuth.get_api_key(:gemini) do
      {:ok, api_key} ->
        url = "https://generativelanguage.googleapis.com/v1beta/models/#{model}:generateContent?key=#{api_key}"

        body = %{
          contents: [
            %{
              parts: [
                %{
                  inline_data: %{
                    mime_type: image_data.mime_type,
                    data: image_data.base64
                  }
                },
                %{
                  text: prompt
                }
              ]
            }
          ],
          generationConfig: %{
            maxOutputTokens: 4096
          }
        }

        case Req.post(url,
               json: body,
               receive_timeout: @default_timeout
             ) do
          {:ok, %{status: 200, body: resp_body}} ->
            extract_google_response(resp_body)

          {:ok, %{status: status, body: error_body}} ->
            {:error, "Google API error (#{status}): #{inspect(error_body)}"}

          {:error, reason} ->
            {:error, "Google request failed: #{inspect(reason)}"}
        end

      {:error, _reason} ->
        {:error, "Google Gemini API key not configured"}
    end
  end

  defp extract_google_response(%{"candidates" => [%{"content" => %{"parts" => parts}} | _]}) do
    text =
      parts
      |> Enum.filter(&Map.has_key?(&1, "text"))
      |> Enum.map(& &1["text"])
      |> Enum.join("")

    if text != "" do
      {:ok, %{analysis: text, provider: "google"}}
    else
      {:error, "Google returned empty response"}
    end
  end

  defp extract_google_response(body) do
    {:error, "Unexpected Google response format: #{inspect(body)}"}
  end
end
