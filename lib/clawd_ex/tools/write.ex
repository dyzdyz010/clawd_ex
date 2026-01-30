defmodule ClawdEx.Tools.Write do
  @moduledoc """
  写入文件内容工具
  """
  @behaviour ClawdEx.Tools.Tool

  @impl true
  def name, do: "write"

  @impl true
  def description do
    "Write content to a file. Creates the file if it doesn't exist, overwrites if it does. Automatically creates parent directories."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        path: %{
          type: "string",
          description: "Path to the file to write (relative or absolute)"
        },
        content: %{
          type: "string",
          description: "Content to write to the file"
        }
      },
      required: ["path", "content"]
    }
  end

  @impl true
  def execute(params, context) do
    path = params["path"] || params[:path]
    content = params["content"] || params[:content]

    resolved_path = resolve_path(path, context)

    # 创建父目录
    dir = Path.dirname(resolved_path)
    File.mkdir_p!(dir)

    case File.write(resolved_path, content) do
      :ok ->
        {:ok, "Successfully wrote #{byte_size(content)} bytes to #{path}"}

      {:error, reason} ->
        {:error, "Failed to write file: #{reason}"}
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
