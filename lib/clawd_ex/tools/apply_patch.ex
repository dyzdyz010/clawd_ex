defmodule ClawdEx.Tools.ApplyPatch do
  @moduledoc """
  Apply a unified diff patch to files in the workspace.
  """

  @behaviour ClawdEx.Tools.Tool

  def name, do: "apply_patch"
  def description, do: "Apply a unified diff patch to files in the workspace"

  def parameters do
    %{
      type: "object",
      properties: %{
        patch: %{type: "string", description: "Unified diff format patch content"}
      },
      required: ["patch"]
    }
  end

  def execute(%{"patch" => patch_content}, context) do
    workspace = Map.get(context, :workspace, File.cwd!())

    # Write patch to temp file
    tmp =
      Path.join(
        System.tmp_dir!(),
        "clawd_patch_#{System.unique_integer([:positive])}.patch"
      )

    File.write!(tmp, patch_content)

    try do
      # Try git apply first
      case System.cmd("git", ["apply", "--stat", tmp], cd: workspace, stderr_to_stdout: true) do
        {stat, 0} ->
          case System.cmd("git", ["apply", tmp], cd: workspace, stderr_to_stdout: true) do
            {_, 0} -> {:ok, %{status: "applied", details: String.trim(stat)}}
            {err, _} -> {:error, "git apply failed: #{String.trim(err)}"}
          end

        {_, _} ->
          # Fallback to patch command
          case System.cmd("patch", ["-p1", "--input", tmp],
                 cd: workspace,
                 stderr_to_stdout: true
               ) do
            {out, 0} -> {:ok, %{status: "applied", details: String.trim(out)}}
            {err, _} -> {:error, "patch failed: #{String.trim(err)}"}
          end
      end
    after
      File.rm(tmp)
    end
  end

  def execute(_, _), do: {:error, "patch parameter is required"}
end
