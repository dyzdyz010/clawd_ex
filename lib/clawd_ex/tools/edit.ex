defmodule ClawdEx.Tools.Edit do
  @moduledoc """
  编辑文件工具 - 精确文本替换，支持 sandbox 路径限制
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

    # Sandbox path check
    case check_sandbox_path(resolved_path, context) do
      :ok ->
        do_edit(resolved_path, path, old_string, new_string)

      {:error, reason} ->
        {:error, "Access denied: #{reason}"}
    end
  end

  defp do_edit(resolved_path, display_path, old_string, new_string) do
    case File.read(resolved_path) do
      {:ok, content} ->
        if String.contains?(content, old_string) do
          # 确保只替换一次
          new_content = String.replace(content, old_string, new_string, global: false)

          case File.write(resolved_path, new_content) do
            :ok ->
              {:ok, "Successfully replaced text in #{display_path}"}

            {:error, reason} ->
              {:error, "Failed to write file: #{reason}"}
          end
        else
          {:error,
           "The specified old_string was not found in the file. Make sure it matches exactly, including whitespace."}
        end

      {:error, :enoent} ->
        {:error, "File not found: #{display_path}"}

      {:error, reason} ->
        {:error, "Failed to read file: #{reason}"}
    end
  end

  defp check_sandbox_path(resolved_path, context) do
    sandbox_mode = sandbox_mode_from_context(context)

    case sandbox_mode do
      :unrestricted ->
        :ok

      mode when mode in [:workspace, :strict] ->
        workspace = context[:workspace]

        if workspace do
          expanded_workspace = Path.expand(workspace)
          expanded_path = Path.expand(resolved_path)

          if String.starts_with?(expanded_path, expanded_workspace) do
            :ok
          else
            {:error, "Path '#{resolved_path}' is outside agent workspace '#{expanded_workspace}'"}
          end
        else
          :ok
        end
    end
  end

  defp sandbox_mode_from_context(context) do
    case Map.get(context, :sandbox_mode) do
      "workspace" -> :workspace
      "strict" -> :strict
      "unrestricted" -> :unrestricted
      nil -> :unrestricted
      other when is_atom(other) -> other
      _ -> :unrestricted
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
