defmodule ClawdExWeb.Api.A2AController do
  @moduledoc """
  A2A REST API controller — Agent-to-Agent communication endpoints.

  Endpoints:
  - POST   /api/v1/a2a/messages         — Send an A2A message
  - GET    /api/v1/a2a/agents            — List registered agents
  - GET    /api/v1/a2a/messages/:agent_id — Get agent's inbox messages
  """
  use ClawdExWeb, :controller

  alias ClawdEx.A2A.{Router, Mailbox, Message}
  alias ClawdEx.Repo

  import Ecto.Query

  action_fallback ClawdExWeb.Api.FallbackController

  @doc """
  POST /api/v1/a2a/messages — Send an A2A message.

  Body:
    {
      "from_agent_id": 1,
      "to_agent_id": 2,
      "content": "Hello",
      "type": "notification",   // optional, default: "notification"
      "priority": 5,            // optional, default: 5
      "metadata": {}            // optional
    }
  """
  def send_message(conn, params) do
    from_agent_id = params["from_agent_id"]
    to_agent_id = params["to_agent_id"]
    content = params["content"]
    msg_type = params["type"] || "notification"
    priority = params["priority"] || 5
    metadata = params["metadata"] || %{}

    cond do
      is_nil(from_agent_id) ->
        {:error, :bad_request, "from_agent_id is required"}

      is_nil(to_agent_id) ->
        {:error, :bad_request, "to_agent_id is required"}

      is_nil(content) || content == "" ->
        {:error, :bad_request, "content is required"}

      msg_type not in Message.types() ->
        {:error, :bad_request, "Invalid type. Must be one of: #{Enum.join(Message.types(), ", ")}"}

      true ->
        case Router.send_message(from_agent_id, to_agent_id, content,
               type: msg_type,
               priority: priority,
               metadata: metadata
             ) do
          {:ok, message_id} ->
            conn
            |> put_status(:created)
            |> json(%{
              data: %{
                message_id: message_id,
                from_agent_id: from_agent_id,
                to_agent_id: to_agent_id,
                type: msg_type,
                priority: priority,
                status: "pending"
              }
            })

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc """
  GET /api/v1/a2a/agents — List registered agents.

  Query params:
    - capability: filter by capability substring
  """
  def list_agents(conn, params) do
    opts =
      if cap = params["capability"] do
        [capability: cap]
      else
        []
      end

    case Router.discover(opts) do
      {:ok, agents} ->
        json(conn, %{
          data: Enum.map(agents, fn a ->
            %{
              agent_id: a.agent_id,
              capabilities: a.capabilities,
              registered_at: a.registered_at
            }
          end),
          total: length(agents)
        })
    end
  end

  @doc """
  GET /api/v1/a2a/messages/:agent_id — Get agent's inbox messages.

  Query params:
    - status: filter by status (default: "pending")
    - limit: max results (default: 20)
  """
  def inbox(conn, %{"agent_id" => agent_id_str} = params) do
    agent_id = String.to_integer(agent_id_str)
    status = params["status"] || "pending"
    limit = parse_int(params["limit"], 20)

    # Get messages from database for this agent
    query =
      from(m in Message,
        where: m.to_agent_id == ^agent_id,
        where: m.status == ^status,
        order_by: [asc: m.priority, asc: m.inserted_at],
        limit: ^limit
      )

    messages = Repo.all(query)

    # Also get in-memory mailbox count
    mailbox_count = Mailbox.count(agent_id)

    json(conn, %{
      data: Enum.map(messages, &format_message/1),
      total: length(messages),
      mailbox_pending: mailbox_count
    })
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp format_message(%Message{} = msg) do
    %{
      id: msg.id,
      message_id: msg.message_id,
      from_agent_id: msg.from_agent_id,
      to_agent_id: msg.to_agent_id,
      type: msg.type,
      content: msg.content,
      priority: msg.priority,
      metadata: msg.metadata,
      status: msg.status,
      reply_to: msg.reply_to,
      inserted_at: msg.inserted_at,
      processed_at: msg.processed_at
    }
  end

  defp parse_int(nil, default), do: default
  defp parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> default
    end
  end
  defp parse_int(val, _default) when is_integer(val), do: val
end
