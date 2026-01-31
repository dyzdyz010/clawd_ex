defmodule ClawdEx.Tools.Compact do
  @moduledoc """
  Compact Tool - 手动触发会话压缩

  允许 AI 在需要时手动请求压缩会话历史。
  """

  @behaviour ClawdEx.Tools.Tool

  alias ClawdEx.Sessions.{Session, Compaction}
  alias ClawdEx.Repo

  @impl true
  def name, do: "compact"

  @impl true
  def description do
    """
    Manually trigger session history compaction.
    Use this when the conversation history is getting long and you want to compress older messages into a summary.
    This helps manage context window limits and can improve response quality by focusing on recent context.
    """
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        instructions: %{
          type: "string",
          description:
            "Optional custom instructions for the summary (e.g., 'Focus on technical decisions')"
        }
      },
      required: []
    }
  end

  @impl true
  def execute(params, context) do
    session_id = context[:session_id]
    instructions = Map.get(params, "instructions")

    case Repo.get(Session, session_id) do
      nil ->
        {:error, "Session not found"}

      session ->
        case Compaction.manual_compact(session, instructions) do
          {:ok, summary} ->
            # 返回压缩结果的简短确认
            summary_preview = String.slice(summary, 0, 200)
            suffix = if String.length(summary) > 200, do: "...", else: ""

            result = %{
              status: "success",
              message: "Compaction completed successfully",
              summary_preview: summary_preview <> suffix,
              summary_length: String.length(summary)
            }

            {:ok, result}

          {:error, reason} ->
            {:error, "Compaction failed: #{inspect(reason)}"}
        end
    end
  end
end
