defmodule ClawdExWeb.Api.GithubWebhookController do
  @moduledoc """
  GitHub Webhook endpoint controller.

  Receives GitHub push events and triggers deployments when
  pushes to the main branch are detected.

  Verifies webhook signature using the `X-Hub-Signature-256` header
  and the configured webhook secret.
  """
  use ClawdExWeb, :controller

  require Logger

  @doc """
  POST /api/webhooks/github — Handle GitHub webhook events
  """
  def handle(conn, params) do
    event = get_req_header(conn, "x-github-event") |> List.first()
    signature = get_req_header(conn, "x-hub-signature-256") |> List.first()

    with :ok <- verify_signature(conn, signature),
         "push" <- event,
         "refs/heads/main" <- params["ref"] do
      Logger.info("GitHub webhook: push to main detected, triggering deploy")

      case ClawdEx.Deploy.Manager.trigger() do
        {:ok, deploy} ->
          json(conn, %{
            status: "deploying",
            deploy_id: deploy.id,
            message: "Deployment triggered by GitHub push"
          })

        {:error, :deploy_in_progress} ->
          json(conn, %{
            status: "skipped",
            message: "Deployment already in progress"
          })
      end
    else
      {:error, :invalid_signature} ->
        Logger.warning("GitHub webhook: invalid signature")

        conn
        |> put_status(401)
        |> json(%{error: "Invalid webhook signature"})

      {:error, :no_secret_configured} ->
        Logger.warning("GitHub webhook: no secret configured")

        conn
        |> put_status(500)
        |> json(%{error: "Webhook secret not configured"})

      _other ->
        # Not a push to main, or different event type — just acknowledge
        json(conn, %{status: "ignored", event: event})
    end
  end

  # --- Signature Verification ---

  defp verify_signature(_conn, nil) do
    # No signature provided — check if we require one
    case get_webhook_secret() do
      nil -> :ok
      _ -> {:error, :invalid_signature}
    end
  end

  defp verify_signature(conn, "sha256=" <> provided_hash) do
    case get_webhook_secret() do
      nil ->
        {:error, :no_secret_configured}

      secret ->
        # Re-read the raw body for HMAC verification
        # We need the raw body before JSON parsing
        raw_body = get_raw_body(conn)

        expected_hash =
          :crypto.mac(:hmac, :sha256, secret, raw_body)
          |> Base.encode16(case: :lower)

        if Plug.Crypto.secure_compare(expected_hash, provided_hash) do
          :ok
        else
          {:error, :invalid_signature}
        end
    end
  end

  defp verify_signature(_conn, _invalid_format) do
    {:error, :invalid_signature}
  end

  defp get_raw_body(conn) do
    # Try to get cached raw body, fall back to re-reading
    case conn.private[:raw_body] do
      nil ->
        # Body may have been consumed by Plug.Parsers
        # In that case, re-encode the params as JSON
        Jason.encode!(conn.params)

      body ->
        body
    end
  end

  defp get_webhook_secret do
    Application.get_env(:clawd_ex, :github_webhook_secret) ||
      System.get_env("GITHUB_WEBHOOK_SECRET")
  end
end
