defmodule ClawdEx.Security.GroupWhitelist do
  @moduledoc """
  Group whitelist checking for channel messages.

  Determines whether a message from a group/channel should be processed
  by a given Agent based on the agent's `allowed_groups` list.

  - Empty `allowed_groups` → allow all groups (backward compatible)
  - Non-empty → only accept messages from whitelisted group IDs
  """

  alias ClawdEx.Agents.Agent

  @doc """
  Check if a message from the given group_id is allowed for the agent.

  Returns:
  - `:allow` — message should be processed
  - `:deny` — message should be silently dropped
  """
  def check(%Agent{allowed_groups: groups}, group_id) do
    cond do
      is_nil(groups) or groups == [] ->
        :allow

      to_string(group_id) in Enum.map(groups, &to_string/1) ->
        :allow

      true ->
        :deny
    end
  end

  def check(nil, _group_id), do: :allow
end
