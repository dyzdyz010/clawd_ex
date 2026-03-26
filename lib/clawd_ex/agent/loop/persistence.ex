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
    # Exclude "system" role — Anthropic Messages API does not allow system messages
    # in the messages array; system prompt is passed as a top-level parameter.
    latest =
      Message
      |> where([m], m.session_id == ^session_id and m.role != :system)
      |> order_by([m], desc: m.inserted_at)
      |> limit(100)

    latest
    |> subquery()
    |> order_by([m], asc: m.inserted_at)
    |> Repo.all()
    |> Enum.map(fn m ->
      # Only restore role + content for history replay.
      # Do NOT restore tool_calls or tool_call_id — these create orphaned
      # tool_use blocks without matching tool_results, causing Anthropic 400 errors.
      # Tool interactions are ephemeral within a single run, not replayed across sessions.
      %{role: to_string(m.role), content: m.content || ""}
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
