defmodule ClawdEx.Tools.Edit do
  @moduledoc """
  编辑文件工具 - 精确文本替换
  """
  @behaviour ClawdEx.Tools.Tool

  @impl true
  def name, do: "edit"

  @impl true
  def description do
    "Edit a file by replacing exact text. The old_string must match exactly (including whitespace). Use this for precise, surgical edits."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        path: %{
          type: "string",
          description: "Path to the file to edit (relative or absolute)"
        },
        old_string: %{
          type: "string",
          description: "Exact text to find and replace (must match exactly)"
        },
        new_string: %{
          type: "string",
          description: "New text to replace the old text with"
        }
      },
      required: ["path", "old_string", "new_string"]
    }
  end

  @impl true
  def execute(params, context) do
    path = params["path"] || params[:path]
    old_string = params["old_string"] || params["oldText"] || params[:old_string]
    new_string = params["new_string"] || params["newText"] || params[:new_string]

    resolved_path = resolve_path(path, context)

    case File.read(resolved_path) do
      {:ok, content} ->
        if String.contains?(content, old_string) do
          # 确保只替换一次
          new_content = String.replace(content, old_string, new_string, global: false)

          case File.write(resolved_path, new_content) do
            :ok ->
              {:ok, "Successfully replaced text in #{path}"}

            {:error, reason} ->
              {:error, "Failed to write file: #{reason}"}
          end
        else
          {:error, "The specified old_string was not found in the file. Make sure it matches exactly, including whitespace."}
        end

      {:error, :enoent} ->
        {:error, "File not found: #{path}"}

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
