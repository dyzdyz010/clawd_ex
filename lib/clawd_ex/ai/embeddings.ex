defmodule ClawdEx.AI.Embeddings do
  @moduledoc """
  嵌入向量生成服务
  支持 OpenAI 和 Gemini 等提供商
  """

  @default_model "text-embedding-3-small"
  @default_provider :openai

  @doc """
  生成文本的嵌入向量
  """
  @spec generate(String.t(), keyword()) :: {:ok, [float()]} | {:error, term()}
  def generate(text, opts \\ []) do
    provider = Keyword.get(opts, :provider, @default_provider)

    case provider do
      :openai -> generate_openai(text, opts)
      :gemini -> generate_gemini(text, opts)
      _ -> {:error, :unsupported_provider}
    end
  end

  @doc """
  返回当前使用的嵌入模型名称
  """
  @spec model() :: String.t()
  def model do
    Application.get_env(:clawd_ex, :embedding_model, @default_model)
  end

  # OpenAI Embeddings API
  defp generate_openai(text, opts) do
    api_key = get_api_key(:openai)
    model = Keyword.get(opts, :model, @default_model)
    base_url = Keyword.get(opts, :base_url, "https://api.openai.com/v1")

    if is_nil(api_key) do
      {:error, :missing_api_key}
    else
      body = Jason.encode!(%{
        input: text,
        model: model
      })

      case Req.post("#{base_url}/embeddings",
        body: body,
        headers: [
          {"Authorization", "Bearer #{api_key}"},
          {"Content-Type", "application/json"}
        ]
      ) do
        {:ok, %{status: 200, body: %{"data" => [%{"embedding" => embedding} | _]}}} ->
          {:ok, embedding}

        {:ok, %{status: status, body: body}} ->
          {:error, {:api_error, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Gemini Embeddings API
  defp generate_gemini(text, opts) do
    api_key = get_api_key(:gemini)
    model = Keyword.get(opts, :model, "gemini-embedding-001")

    if is_nil(api_key) do
      {:error, :missing_api_key}
    else
      url = "https://generativelanguage.googleapis.com/v1beta/models/#{model}:embedContent?key=#{api_key}"

      body = Jason.encode!(%{
        model: "models/#{model}",
        content: %{
          parts: [%{text: text}]
        }
      })

      case Req.post(url,
        body: body,
        headers: [{"Content-Type", "application/json"}]
      ) do
        {:ok, %{status: 200, body: %{"embedding" => %{"values" => embedding}}}} ->
          {:ok, embedding}

        {:ok, %{status: status, body: body}} ->
          {:error, {:api_error, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp get_api_key(:openai) do
    Application.get_env(:clawd_ex, :openai_api_key) ||
      System.get_env("OPENAI_API_KEY")
  end

  defp get_api_key(:gemini) do
    Application.get_env(:clawd_ex, :gemini_api_key) ||
      System.get_env("GEMINI_API_KEY")
  end
end
