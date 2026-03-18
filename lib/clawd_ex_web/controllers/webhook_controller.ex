defmodule ClawdExWeb.WebhookController do
  @moduledoc """
  Webhook endpoints — 接收外部 webhook 触发 agent 执行，验证签名，路由到处理器。
  """
  use ClawdExWeb, :controller

  require Logger

  alias ClawdEx.Webhooks.Manager

  # ============================================================================
  # POST /api/webhooks/:webhook_id/trigger
  # ============================================================================

  @doc """
  Trigger a webhook by ID — 外部 HTTP 触发 agent 执行。

  Accepts an optional `session_key` in the payload to target a specific session.
  """
  def trigger(conn, %{"webhook_id" => webhook_id} = params) do
    case Manager.trigger_webhook(webhook_id, params) do
      {:ok, result} ->
        json(conn, %{status: "triggered", result: result})

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "Webhook not found"})

      {:error, reason} ->
        conn |> put_status(422) |> json(%{error: inspect(reason)})
    end
  end

  # ============================================================================
  # POST /api/webhooks/inbound/generic
  # ============================================================================

  @doc """
  Generic inbound webhook — routes based on headers (GitHub, GitLab, etc.).
  No signature verification required.
  """
  def inbound_generic(conn, params) do
    source = detect_source(conn, params)

    {:ok, result} = Manager.handle_inbound(source, params)
    json(conn, %{status: "received", source: source, result: result})
  end

  defp detect_source(conn, _params) do
    cond do
      get_req_header(conn, "x-github-event") != [] -> "github"
      get_req_header(conn, "x-gitlab-event") != [] -> "gitlab"
      true -> "generic"
    end
  end

  # ============================================================================
  # POST /api/webhooks/inbound (signature-verified)
  # ============================================================================

  @doc """
  POST /api/webhooks/inbound

  Expects:
  - X-Webhook-Signature header (HMAC-SHA256)
  - X-Webhook-Secret-Name header (identifies which webhook secret to use)
  - JSON body
  """
  def inbound(conn, params) do
    with {:ok, raw_body} <- read_raw_body(conn),
         {:ok, signature} <- get_signature(conn),
         {:ok, secret_name} <- get_secret_name(conn),
         {:ok, webhook} <- find_webhook(secret_name),
         :ok <- verify(raw_body, webhook.secret, signature) do
      event_type = get_event_type(conn, params)

      Logger.info("Inbound webhook received: #{event_type} via #{secret_name}")

      route_event(event_type, params)

      json(conn, %{status: "accepted", event: event_type})
    else
      {:error, :missing_signature} ->
        conn |> put_status(401) |> json(%{error: "Missing X-Webhook-Signature header"})

      {:error, :missing_secret_name} ->
        conn |> put_status(400) |> json(%{error: "Missing X-Webhook-Secret-Name header"})

      {:error, :webhook_not_found} ->
        conn |> put_status(404) |> json(%{error: "Webhook not found"})

      {:error, :invalid_signature} ->
        conn |> put_status(401) |> json(%{error: "Invalid signature"})

      {:error, :no_body} ->
        conn |> put_status(400) |> json(%{error: "Empty request body"})
    end
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp read_raw_body(conn) do
    case conn.assigns[:raw_body] do
      nil ->
        # Fallback: re-encode params (body already parsed by Plug.Parsers)
        case Jason.encode(conn.params) do
          {:ok, body} -> {:ok, body}
          _ -> {:error, :no_body}
        end

      raw when is_binary(raw) ->
        {:ok, raw}
    end
  end

  defp get_signature(conn) do
    case get_req_header(conn, "x-webhook-signature") do
      [sig | _] -> {:ok, sig}
      [] -> {:error, :missing_signature}
    end
  end

  defp get_secret_name(conn) do
    case get_req_header(conn, "x-webhook-secret-name") do
      [name | _] -> {:ok, name}
      [] -> {:error, :missing_secret_name}
    end
  end

  defp find_webhook(secret_name) do
    case ClawdEx.Repo.get_by(ClawdEx.Webhooks.Webhook, name: secret_name) do
      nil -> {:error, :webhook_not_found}
      webhook -> {:ok, webhook}
    end
  end

  defp verify(raw_body, secret, signature) do
    if Manager.verify_signature(raw_body, secret, signature) do
      :ok
    else
      {:error, :invalid_signature}
    end
  end

  defp get_event_type(conn, params) do
    # Check header first, then payload field
    case get_req_header(conn, "x-webhook-event") do
      [event | _] -> event
      [] -> params["event"] || params["type"] || "unknown"
    end
  end

  defp route_event(event_type, payload) do
    case event_type do
      "message.inject" ->
        handle_message_inject(payload)

      "task.create" ->
        handle_task_create(payload)

      _ ->
        # Broadcast for any custom handlers
        Phoenix.PubSub.broadcast(
          ClawdEx.PubSub,
          "webhooks:inbound",
          {:webhook_event, event_type, payload}
        )
    end
  end

  defp handle_message_inject(%{"session_key" => session_key, "content" => content}) do
    case ClawdEx.Sessions.SessionManager.find_session(session_key) do
      {:ok, pid} ->
        GenServer.cast(pid, {:inject_message, content})
        :ok

      :not_found ->
        Logger.warning("Webhook message inject: session #{session_key} not found")
        :ok
    end
  end

  defp handle_message_inject(_), do: :ok

  defp handle_task_create(%{"title" => title} = payload) do
    attrs = %{
      title: title,
      description: payload["description"],
      priority: payload["priority"] || 5,
      context: payload["context"] || %{}
    }

    attrs =
      if payload["agent_id"],
        do: Map.put(attrs, :agent_id, payload["agent_id"]),
        else: attrs

    case ClawdEx.Tasks.Manager.create_task(attrs) do
      {:ok, task} ->
        Logger.info("Webhook created task #{task.id}: #{title}")

      {:error, reason} ->
        Logger.warning("Webhook task creation failed: #{inspect(reason)}")
    end
  end

  defp handle_task_create(_), do: :ok
end
