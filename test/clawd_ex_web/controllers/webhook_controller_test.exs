defmodule ClawdExWeb.WebhookControllerTest do
  use ClawdExWeb.ConnCase

  alias ClawdEx.Repo
  alias ClawdEx.Webhooks.Webhook

  describe "POST /api/webhooks/:webhook_id/trigger" do
    test "returns 404 when webhook does not exist", %{conn: conn} do
      conn = post(conn, ~p"/api/webhooks/999999/trigger", %{data: "test"})

      assert json_response(conn, 404) == %{"error" => "Webhook not found"}
    end

    test "triggers webhook and returns success (broadcast mode)", %{conn: conn} do
      {:ok, webhook} =
        %Webhook{}
        |> Webhook.changeset(%{
          name: "test-trigger-webhook",
          url: "https://example.com/hook",
          secret: "test-secret-123",
          events: ["test.event"]
        })
        |> Repo.insert()

      conn =
        post(conn, ~p"/api/webhooks/#{webhook.id}/trigger", %{
          message: "hello from test"
        })

      body = json_response(conn, 200)
      assert body["status"] == "triggered"
      assert body["result"]["broadcast"] == true
      assert body["result"]["webhook_id"] == webhook.id
    end

    test "triggers webhook with session_key returns session_not_found", %{conn: conn} do
      {:ok, webhook} =
        %Webhook{}
        |> Webhook.changeset(%{
          name: "test-session-webhook",
          url: "https://example.com/hook",
          secret: "test-secret-456",
          events: ["test.event"]
        })
        |> Repo.insert()

      conn =
        post(conn, ~p"/api/webhooks/#{webhook.id}/trigger", %{
          session_key: "nonexistent-session",
          data: "test"
        })

      body = json_response(conn, 422)
      assert body["error"] =~ "session_not_found"
    end
  end

  describe "POST /api/webhooks/inbound/generic" do
    test "returns received status for generic source", %{conn: conn} do
      conn = post(conn, ~p"/api/webhooks/inbound/generic", %{event: "push", data: "test"})

      body = json_response(conn, 200)
      assert body["status"] == "received"
      assert body["source"] == "generic"
      assert body["result"]["received"] == true
    end

    test "detects GitHub source from header", %{conn: conn} do
      conn =
        conn
        |> put_req_header("x-github-event", "push")
        |> post(~p"/api/webhooks/inbound/generic", %{ref: "refs/heads/main"})

      body = json_response(conn, 200)
      assert body["source"] == "github"
    end

    test "detects GitLab source from header", %{conn: conn} do
      conn =
        conn
        |> put_req_header("x-gitlab-event", "Push Hook")
        |> post(~p"/api/webhooks/inbound/generic", %{ref: "refs/heads/main"})

      body = json_response(conn, 200)
      assert body["source"] == "gitlab"
    end
  end
end
