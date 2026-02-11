defmodule ClawdEx.Skills.Skill do
  @moduledoc """
  Represents a single skill loaded from a SKILL.md file.

  A skill is defined by its YAML frontmatter (name, description, metadata)
  and its markdown body content.
  """

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          location: String.t(),
          metadata: map(),
          content: String.t(),
          enabled: boolean(),
          source: :bundled | :managed | :workspace
        }

  @enforce_keys [:name, :description, :location, :content]
  defstruct [
    :name,
    :description,
    :location,
    :content,
    metadata: %{},
    enabled: true,
    source: :bundled
  ]
end
