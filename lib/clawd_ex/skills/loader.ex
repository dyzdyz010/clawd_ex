defmodule ClawdEx.Skills.Loader do
  @moduledoc """
  Loads skills from SKILL.md files across multiple directories.

  Scans three locations with priority (higher wins on name conflict):
  1. workspace/skills (workspace)
  2. ~/.clawd/skills (managed)
  3. priv/skills (bundled)

  Also supports extra directories via config `:extra_skill_dirs`.
  """

  alias ClawdEx.Skills.Skill

  @skill_filename "SKILL.md"

  @doc """
  Load all skills from all configured directories.

  Returns a list of `%Skill{}` structs, deduplicated by name with
  workspace > managed > bundled priority.
  """
  @spec load_all(keyword()) :: [Skill.t()]
  def load_all(opts \\ []) do
    dirs = skill_dirs(opts)

    # Load in priority order (lowest first), later entries overwrite earlier ones
    dirs
    |> Enum.flat_map(fn {dir, source} -> load_dir(dir, source) end)
    |> deduplicate_by_name()
  end

  @doc """
  Parse a single SKILL.md file and return a Skill struct.
  """
  @spec parse_skill_file(String.t(), atom()) :: {:ok, Skill.t()} | {:error, term()}
  def parse_skill_file(path, source \\ :bundled) do
    case File.read(path) do
      {:ok, content} ->
        case parse_frontmatter(content) do
          {:ok, frontmatter, _body} ->
            name = Map.get(frontmatter, "name")
            description = Map.get(frontmatter, "description")

            if name && description do
              metadata = parse_metadata(Map.get(frontmatter, "metadata", %{}))

              {:ok,
               %Skill{
                 name: name,
                 description: description,
                 location: Path.expand(path),
                 metadata: metadata,
                 content: content,
                 source: source
               }}
            else
              {:error, :missing_required_fields}
            end

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Parse YAML frontmatter from a SKILL.md content string.

  Returns `{:ok, frontmatter_map, body}` or `{:error, reason}`.
  """
  @spec parse_frontmatter(String.t()) :: {:ok, map(), String.t()} | {:error, term()}
  def parse_frontmatter(content) do
    case Regex.run(~r/\A---\s*\n(.*?)\n---\s*\n?(.*)\z/s, content) do
      [_, yaml_str, body] ->
        case YamlElixir.read_from_string(yaml_str) do
          {:ok, parsed} when is_map(parsed) ->
            {:ok, parsed, body}

          {:ok, _} ->
            {:error, :invalid_frontmatter}

          {:error, reason} ->
            {:error, reason}
        end

      nil ->
        {:error, :no_frontmatter}
    end
  end

  @doc """
  Return the list of skill directories to scan, in priority order (lowest first).
  """
  @spec skill_dirs(keyword()) :: [{String.t(), atom()}]
  def skill_dirs(opts \\ []) do
    workspace = Keyword.get(opts, :workspace)

    bundled_dir = Path.join(:code.priv_dir(:clawd_ex) |> to_string(), "skills")
    managed_dir = Path.expand("~/.clawd/skills")

    workspace_dir =
      if workspace, do: Path.join(Path.expand(workspace), "skills"), else: nil

    extra_dirs =
      Keyword.get(opts, :extra_dirs, Application.get_env(:clawd_ex, :extra_skill_dirs, []))

    dirs = [
      {bundled_dir, :bundled},
      {managed_dir, :managed}
    ]

    dirs = dirs ++ Enum.map(extra_dirs, fn d -> {Path.expand(d), :managed} end)

    dirs =
      if workspace_dir do
        dirs ++ [{workspace_dir, :workspace}]
      else
        dirs
      end

    dirs
    |> Enum.filter(fn {dir, _} -> File.dir?(dir) end)
  end

  # Scan a directory for skill folders containing SKILL.md
  defp load_dir(dir, source) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.map(fn entry -> Path.join(dir, entry) end)
        |> Enum.filter(&File.dir?/1)
        |> Enum.map(fn skill_dir ->
          skill_file = Path.join(skill_dir, @skill_filename)

          if File.exists?(skill_file) do
            case parse_skill_file(skill_file, source) do
              {:ok, skill} -> skill
              {:error, _} -> nil
            end
          else
            nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      {:error, _} ->
        []
    end
  end

  # Parse metadata field - can be a JSON string or already a map
  defp parse_metadata(metadata) when is_map(metadata), do: metadata

  defp parse_metadata(metadata) when is_binary(metadata) do
    case Jason.decode(metadata) do
      {:ok, parsed} when is_map(parsed) -> parsed
      _ -> %{}
    end
  end

  defp parse_metadata(_), do: %{}

  # Deduplicate skills by name, keeping later entries (higher priority)
  defp deduplicate_by_name(skills) do
    skills
    |> Enum.reduce(%{}, fn skill, acc ->
      Map.put(acc, skill.name, skill)
    end)
    |> Map.values()
  end
end
