defmodule ClawdExWeb.AgentFormComponents do
  @moduledoc false
  use ClawdExWeb, :html

  embed_templates "agent_form_components/*"

  defp input_error_class(field) do
    if field.errors != [], do: " border-red-500", else: ""
  end

  defp format_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
    end)
  end
end
