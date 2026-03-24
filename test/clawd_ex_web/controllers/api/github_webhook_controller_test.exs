defmodule ClawdExWeb.Api.GithubWebhookControllerTest do
  use ClawdExWeb.ConnCase

  describe "POST /api/webhooks/github" do
    test "triggers deploy on push to main", %{conn: conn} do
      payload = %{
        "ref" => "refs/heads/main",
        "after" => "abc123",
        "repository" => %{"full_name" => "hemifuture/clawd_ex"}
      }

      conn =
        conn
        |> put_req_header("x-github-event", "push")
        |> put_req_header("content-type", "application/json")
        |> post("/api/webhooks/github", payload)

      body = json_response(conn, 200)
      assert body["status"] in ["deploying", "skipped"]

      # Wait for async deploy to complete if triggered
      Process.sleep(2_000)
    end

    test "ignores non-push events", %{conn: conn} do
      payload = %{
        "action" => "opened",
        "pull_request" => %{"number" => 1}
      }

      conn =
        conn
        |> put_req_header("x-github-event", "pull_request")
        |> put_req_header("content-type", "application/json")
        |> post("/api/webhooks/github", payload)

      body = json_response(conn, 200)
      assert body["status"] == "ignored"
    end

    test "ignores push to non-main branch", %{conn: conn} do
      payload = %{
        "ref" => "refs/heads/feature/test",
        "after" => "abc123"
      }

      conn =
        conn
        |> put_req_header("x-github-event", "push")
        |> put_req_header("content-type", "application/json")
        |> post("/api/webhooks/github", payload)

      body = json_response(conn, 200)
      assert body["status"] == "ignored"
    end

    test "rejects invalid signature when secret is configured", %{conn: conn} do
      # Set a webhook secret for this test
      Application.put_env(:clawd_ex, :github_webhook_secret, "test_secret_123")

      payload = %{
        "ref" => "refs/heads/main",
        "after" => "abc123"
      }

      conn =
        conn
        |> put_req_header("x-github-event", "push")
        |> put_req_header("x-hub-signature-256", "sha256=invalid_hash")
        |> put_req_header("content-type", "application/json")
        |> post("/api/webhooks/github", payload)

      assert json_response(conn, 401)

      # Clean up
      Application.delete_env(:clawd_ex, :github_webhook_secret)
    end

    test "validates correct signature", %{conn: conn} do
      secret = "test_secret_valid"
      Application.put_env(:clawd_ex, :github_webhook_secret, secret)

      payload = %{
        "ref" => "refs/heads/main",
        "after" => "abc123",
        "repository" => %{"full_name" => "hemifuture/clawd_ex"}
      }

      # Compute correct HMAC signature
      # Note: The controller falls back to Jason.encode!(conn.params) when raw_body is not cached,
      # so we need to compute signature over the JSON-encoded params as they arrive
      body_json = Jason.encode!(payload)
      hash = :crypto.mac(:hmac, :sha256, secret, body_json) |> Base.encode16(case: :lower)

      conn =
        conn
        |> put_req_header("x-github-event", "push")
        |> put_req_header("x-hub-signature-256", "sha256=#{hash}")
        |> put_req_header("content-type", "application/json")
        |> post("/api/webhooks/github", payload)

      body = json_response(conn, 200)
      assert body["status"] in ["deploying", "skipped"]

      # Clean up
      Application.delete_env(:clawd_ex, :github_webhook_secret)
      Process.sleep(2_000)
    end
  end
end
