defmodule ClawdExWeb.WebhooksLiveTest do
  use ClawdExWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  alias ClawdEx.Repo
  alias ClawdEx.Webhooks.Webhook

  defp create_webhook(attrs \\ %{}) do
    defaults = %{
      name: "test-webhook-#{System.unique_integer([:positive])}",
      url: "https://example.com/webhook",
      secret: "test-secret-#{System.unique_integer([:positive])}",
      events: ["message.created"],
      enabled: true
    }

    {:ok, webhook} =
      %Webhook{}
      |> Webhook.changeset(Map.merge(defaults, attrs))
      |> Repo.insert()

    webhook
  end

  describe "mount" do
    test "renders webhooks page with title", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/webhooks")

      assert html =~ "Webhooks"
      assert html =~ "Manage outbound webhook endpoints"
    end

    test "shows empty state when no webhooks", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/webhooks")

      assert html =~ "No webhooks configured"
      assert html =~ "Create your first webhook"
    end

    test "contains key UI elements", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/webhooks")

      assert html =~ "Webhooks"
      assert html =~ "New Webhook"
      assert html =~ "Total Webhooks"
      assert html =~ "Enabled"
      assert html =~ "Disabled"
    end

    test "renders webhooks when they exist", %{conn: conn} do
      create_webhook(%{name: "My Webhook"})
      {:ok, _view, html} = live(conn, "/webhooks")

      assert html =~ "My Webhook"
      refute html =~ "No webhooks configured"
    end
  end

  describe "events" do
    test "show_form event opens the form modal", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/webhooks")

      html = render_click(view, "show_form")
      assert html =~ ~s(name="webhook[name]")
      assert html =~ ~s(name="webhook[url]")
      assert html =~ ~s(name="webhook[secret]")
    end

    test "close_form event hides the form modal", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/webhooks")

      render_click(view, "show_form")
      html = render_click(view, "close_form")

      refute html =~ ~s(name="webhook[name]")
    end

    test "toggle event toggles webhook enabled state", %{conn: conn} do
      webhook = create_webhook(%{enabled: true})
      {:ok, view, _html} = live(conn, "/webhooks")

      render_click(view, "toggle", %{"id" => to_string(webhook.id)})

      updated = Repo.get!(Webhook, webhook.id)
      refute updated.enabled
    end

    test "expand event does not crash", %{conn: conn} do
      webhook = create_webhook()
      {:ok, view, _html} = live(conn, "/webhooks")

      html = render_click(view, "expand", %{"id" => to_string(webhook.id)})
      assert html =~ "Details"
      assert html =~ "Subscribed Events"

      # Toggle collapse
      html = render_click(view, "expand", %{"id" => to_string(webhook.id)})
      assert html =~ "Webhooks"
    end

    test "toggle_event event toggles event selection in form", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/webhooks")

      render_click(view, "show_form")
      html = render_click(view, "toggle_event", %{"event" => "message.created"})
      assert html =~ "message.created"
    end

    test "generate_secret event generates a secret", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/webhooks")

      render_click(view, "show_form")
      html = render_click(view, "generate_secret")
      assert html =~ ~s(name="webhook[secret]")
    end

    test "validate_form event does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/webhooks")

      render_click(view, "show_form")
      html = render_change(view, "validate_form", %{"webhook" => %{"name" => "test", "url" => "https://x.com", "secret" => "s"}})
      assert html =~ ~s(name="webhook[name]")
    end

    test "save_webhook creates a new webhook", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/webhooks")

      render_click(view, "show_form")
      render_click(view, "toggle_event", %{"event" => "message.created"})

      html =
        view
        |> form("form", %{"webhook" => %{"name" => "New Hook", "url" => "https://example.com/hook", "secret" => "mysecret123"}})
        |> render_submit()

      # After save, the new webhook appears in the list
      assert html =~ "New Hook"
      # Form should be closed - no form inputs visible
      refute html =~ ~s(name="webhook[name]")
    end

    test "delete event removes a webhook", %{conn: conn} do
      webhook = create_webhook(%{name: "To Delete"})
      {:ok, view, html} = live(conn, "/webhooks")
      assert html =~ "To Delete"

      html = render_click(view, "delete", %{"id" => to_string(webhook.id)})
      refute html =~ "To Delete"
      # Should show empty state after deletion
      assert html =~ "No webhooks configured"
    end

    test "edit event opens form with webhook data", %{conn: conn} do
      webhook = create_webhook(%{name: "Editable Hook"})
      {:ok, view, _html} = live(conn, "/webhooks")

      html = render_click(view, "edit", %{"id" => to_string(webhook.id)})
      assert html =~ "Edit Webhook"
      assert html =~ "Editable Hook"
    end
  end
end
