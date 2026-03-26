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

  test "renders webhooks page with key elements", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/webhooks")

    assert html =~ "Webhooks"
    assert html =~ "Manage outbound webhook endpoints"
    assert html =~ "No webhooks configured"
    assert html =~ "New Webhook"
    assert html =~ "Total Webhooks"
  end

  test "renders webhooks when they exist", %{conn: conn} do
    create_webhook(%{name: "My Webhook"})
    {:ok, _view, html} = live(conn, "/webhooks")

    assert html =~ "My Webhook"
    refute html =~ "No webhooks configured"
  end

  test "form modal open/close and creation", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/webhooks")

    # Open form
    html = render_click(view, "show_form")
    assert html =~ ~s(name="webhook[name]")

    # Close form
    html = render_click(view, "close_form")
    refute html =~ ~s(name="webhook[name]")

    # Create webhook
    render_click(view, "show_form")
    render_click(view, "toggle_event", %{"event" => "message.created"})

    html =
      view
      |> form("form", %{"webhook" => %{"name" => "New Hook", "url" => "https://example.com/hook", "secret" => "mysecret123"}})
      |> render_submit()

    assert html =~ "New Hook"
    refute html =~ ~s(name="webhook[name]")
  end

  test "toggle webhook enabled state", %{conn: conn} do
    webhook = create_webhook(%{enabled: true})
    {:ok, view, _html} = live(conn, "/webhooks")

    render_click(view, "toggle", %{"id" => to_string(webhook.id)})

    updated = Repo.get!(Webhook, webhook.id)
    refute updated.enabled
  end

  test "expand shows details", %{conn: conn} do
    webhook = create_webhook()
    {:ok, view, _html} = live(conn, "/webhooks")

    html = render_click(view, "expand", %{"id" => to_string(webhook.id)})
    assert html =~ "Details"
    assert html =~ "Subscribed Events"
  end

  test "delete removes a webhook", %{conn: conn} do
    webhook = create_webhook(%{name: "To Delete"})
    {:ok, view, html} = live(conn, "/webhooks")
    assert html =~ "To Delete"

    html = render_click(view, "delete", %{"id" => to_string(webhook.id)})
    refute html =~ "To Delete"
  end

  test "edit opens form with webhook data", %{conn: conn} do
    webhook = create_webhook(%{name: "Editable Hook"})
    {:ok, view, _html} = live(conn, "/webhooks")

    html = render_click(view, "edit", %{"id" => to_string(webhook.id)})
    assert html =~ "Edit Webhook"
    assert html =~ "Editable Hook"
  end
end
