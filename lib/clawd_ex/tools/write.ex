defmodule ClawdEx.Tools.Write do
  @moduledoc """
  写入文件内容工具 — 支持 sandbox 路径限制
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

    # Sandbox path check
    case check_sandbox_path(resolved_path, context) do
      :ok ->
        # 创建父目录
        dir = Path.dirname(resolved_path)
        File.mkdir_p!(dir)

        case File.write(resolved_path, content) do
          :ok ->
            {:ok, "Successfully wrote #{byte_size(content)} bytes to #{path}"}

          {:error, reason} ->
            {:error, "Failed to write file: #{reason}"}
        end

      {:error, reason} ->
        {:error, "Access denied: #{reason}"}
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
