defmodule ClawdEx.Tools.Read do
  @moduledoc """
  读取文件内容工具
  """
  @behaviour ClawdEx.Tools.Tool

  @impl true
  def name, do: "read"

  @impl true
  def description do
    "Read the contents of a file. Supports text files. Output is truncated to 2000 lines or 50KB (whichever is hit first). Use offset/limit for large files."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        path: %{
          type: "string",
          description: "Path to the file to read (relative or absolute)"
        },
        offset: %{
          type: "integer",
          description: "Line number to start reading from (1-indexed)"
        },
        limit: %{
          type: "integer",
          description: "Maximum number of lines to read"
        }
      },
      required: ["path"]
    }
  end

  @impl true
  def execute(params, context) do
    path = params["path"] || params[:path]
    offset = params["offset"] || params[:offset] || 1
    limit = params["limit"] || params[:limit] || 2000

    # 解析路径
    resolved_path = resolve_path(path, context)

    case File.read(resolved_path) do
      {:ok, content} ->
        lines = String.split(content, "\n")

        # 应用 offset 和 limit
        selected_lines = lines
        |> Enum.drop(offset - 1)
        |> Enum.take(limit)

        result = Enum.join(selected_lines, "\n")

        # 检查大小限制 (50KB)
        if byte_size(result) > 50_000 do
          truncated = String.slice(result, 0, 50_000)
          {:ok, truncated <> "\n\n[Output truncated at 50KB]"}
        else
          {:ok, result}
        end

      {:error, :enoent} ->
        {:error, "File not found: #{path}"}

      {:error, :eisdir} ->
        # 如果是目录，列出内容
        case File.ls(resolved_path) do
          {:ok, files} ->
            {:ok, "Directory listing:\n" <> Enum.join(files, "\n")}
          {:error, reason} ->
            {:error, "Cannot read directory: #{reason}"}
        end

      {:error, reason} ->
        {:error, "Failed to read file: #{reason}"}
    end
  end

  defp resolve_path(path, context) do
    cond do
      String.starts_with?(path, "/") -> path
      String.starts_with?(path, "~") -> Path.expand(path)
      context[:workspace] -> Path.join(context[:workspace], path)
      true -> Path.expand(path)
    end
  end
end
