defmodule ClawdEx.Tools.MemoryGet do
  @moduledoc """
  读取记忆文件内容工具

  从 workspace 中读取 MEMORY.md 或 memory/*.md 文件。
  """
  @behaviour ClawdEx.Tools.Tool

  alias ClawdEx.Memory.Config

  @impl true
  def name, do: "memory_get"

  @impl true
  def description do
    "Read content from MEMORY.md or memory/*.md files. Use after memory_search to pull only the needed lines and keep context small."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        path: %{
          type: "string",
          description: "Memory file path (e.g., 'MEMORY.md' or 'memory/2024-01-30.md')"
        },
        from: %{
          type: "integer",
          description: "Starting line number (1-indexed)"
        },
        lines: %{
          type: "integer",
          description: "Number of lines to read"
        }
      },
      required: ["path"]
    }
  end

  @impl true
  def execute(params, context) do
    path = params["path"] || params[:path]
    from_line = params["from"] || params[:from]
    num_lines = params["lines"] || params[:lines]

    # 验证路径安全性
    unless valid_memory_path?(path) do
      {:error, "Invalid memory path. Only MEMORY.md and memory/*.md are allowed."}
    else
      # 获取 workspace 路径
      workspace =
        context[:workspace] ||
          Config.local_file()[:workspace] ||
          Path.expand("~/.clawd/workspace")

      full_path = Path.join(workspace, path)

      case File.read(full_path) do
        {:ok, content} ->
          lines = String.split(content, "\n")

          selected =
            cond do
              from_line && num_lines ->
                lines |> Enum.drop(from_line - 1) |> Enum.take(num_lines)

              from_line ->
                Enum.drop(lines, from_line - 1)

              num_lines ->
                Enum.take(lines, num_lines)

              true ->
                lines
            end

          {:ok, Enum.join(selected, "\n")}

        {:error, :enoent} ->
          {:error, "Memory file not found: #{path}"}

        {:error, reason} ->
          {:error, "Failed to read memory file: #{reason}"}
      end
    end
  end

  defp valid_memory_path?(path) do
    path == "MEMORY.md" ||
      (String.starts_with?(path, "memory/") && String.ends_with?(path, ".md"))
  end
end
