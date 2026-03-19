defmodule ClawdEx.Agent.Loop.Persistence do
  @moduledoc """
  Message persistence for the agent loop.

  Handles loading conversation history and saving messages to the database.
  """

  import Ecto.Query

  alias ClawdEx.Sessions.Message
  alias ClawdEx.Repo

  @doc "Load recent session messages (up to 100, ordered ascending)"
  def load_session_messages(session_id) do
    # Subquery: get the latest 100 messages (desc), then re-order ascending
    latest =
      Message
      |> where([m], m.session_id == ^session_id)
      |> order_by([m], desc: m.inserted_at)
      |> limit(100)

    latest
    |> subquery()
    |> order_by([m], asc: m.inserted_at)
    |> Repo.all()
    |> Enum.map(fn m ->
      base = %{role: to_string(m.role), content: m.content}

      # Add tool call fields if present
      base =
        if m.tool_calls && m.tool_calls != [] do
          Map.put(base, :tool_calls, m.tool_calls)
        else
          base
        end

      if m.tool_call_id do
        Map.put(base, :tool_call_id, m.tool_call_id)
      else
        base
      end
    end)
  end

  @doc "Save a message to the database"
  def save_message(session_id, role, content, opts \\ []) do
    %Message{}
    |> Message.changeset(%{
      session_id: session_id,
      role: role,
      content: content,
      tool_calls: Keyword.get(opts, :tool_calls, []),
      tool_call_id: Keyword.get(opts, :tool_call_id),
      model: Keyword.get(opts, :model),
      tokens_in: Keyword.get(opts, :tokens_in),
      tokens_out: Keyword.get(opts, :tokens_out)
    })
    |> Repo.insert!()
  end
end
