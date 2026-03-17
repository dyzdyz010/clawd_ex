defmodule ClawdExWeb.WebhooksLive do
  @moduledoc """
  Webhooks management page — list, create, test, enable/disable, view delivery history.
  """
  use ClawdExWeb, :live_view

  import Ecto.Query

  alias ClawdEx.Webhooks.{Manager, Webhook, Delivery}
  alias ClawdEx.Repo

  @available_events ~w(
    message.created message.inject
    session.created session.completed
    task.created task.updated task.completed
    agent.started agent.stopped
    a2a.request a2a.response
  )

  @impl true
  def mount(_params, _session, socket) do
    webhooks = Manager.list_webhooks()

    {:ok,
     assign(socket,
       page_title: "Webhooks",
       webhooks: webhooks,
       expanded: nil,
       show_form: false,
       editing: nil,
       form: default_form(),
       form_errors: %{},
       available_events: @available_events,
       testing: nil
     )}
  end

  @impl true
  def handle_event("toggle", %{"id" => id}, socket) do
    case Repo.get(Webhook, id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Webhook not found")}

      webhook ->
        {:ok, _} = Manager.update_webhook(webhook.id, %{enabled: !webhook.enabled})
        {:noreply, assign(socket, webhooks: Manager.list_webhooks())}
    end
  end

  @impl true
  def handle_event("expand", %{"id" => id}, socket) do
    id = String.to_integer(id)
    expanded = if socket.assigns.expanded == id, do: nil, else: id

    socket =
      if expanded do
        deliveries = load_deliveries(id)
        assign(socket, expanded: expanded, deliveries: deliveries)
      else
        assign(socket, expanded: nil)
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("show_form", _params, socket) do
    {:noreply, assign(socket, show_form: true, editing: nil, form: default_form(), form_errors: %{})}
  end

  @impl true
  def handle_event("edit", %{"id" => id}, socket) do
    case Repo.get(Webhook, String.to_integer(id)) do
      nil ->
        {:noreply, put_flash(socket, :error, "Webhook not found")}

      webhook ->
        form = %{
          "name" => webhook.name,
          "url" => webhook.url,
          "secret" => webhook.secret,
          "events" => webhook.events
        }

        {:noreply, assign(socket, show_form: true, editing: webhook.id, form: form, form_errors: %{})}
    end
  end

  @impl true
  def handle_event("close_form", _params, socket) do
    {:noreply, assign(socket, show_form: false, editing: nil, form_errors: %{})}
  end

  @impl true
  def handle_event("toggle_event", %{"event" => event}, socket) do
    events = socket.assigns.form["events"] || []

    events =
      if event in events,
        do: List.delete(events, event),
        else: events ++ [event]

    form = Map.put(socket.assigns.form, "events", events)
    {:noreply, assign(socket, form: form)}
  end

  @impl true
  def handle_event("validate_form", %{"webhook" => params}, socket) do
    form =
      socket.assigns.form
      |> Map.put("name", params["name"] || "")
      |> Map.put("url", params["url"] || "")
      |> Map.put("secret", params["secret"] || "")

    {:noreply, assign(socket, form: form)}
  end

  @impl true
  def handle_event("save_webhook", %{"webhook" => params}, socket) do
    form =
      socket.assigns.form
      |> Map.put("name", params["name"] || "")
      |> Map.put("url", params["url"] || "")
      |> Map.put("secret", params["secret"] || "")

    attrs = %{
      name: form["name"],
      url: form["url"],
      secret: form["secret"],
      events: form["events"] || []
    }

    result =
      if socket.assigns.editing do
        Manager.update_webhook(socket.assigns.editing, attrs)
      else
        Manager.register_webhook(attrs)
      end

    case result do
      {:ok, _webhook} ->
        action = if socket.assigns.editing, do: "updated", else: "created"

        {:noreply,
         socket
         |> assign(
           webhooks: Manager.list_webhooks(),
           show_form: false,
           editing: nil,
           form: default_form(),
           form_errors: %{}
         )
         |> put_flash(:info, "Webhook #{action} successfully")}

      {:error, %Ecto.Changeset{} = changeset} ->
        errors =
          Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
            Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
              opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
            end)
          end)

        {:noreply, assign(socket, form: form, form_errors: errors)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    case Manager.delete_webhook(String.to_integer(id)) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(webhooks: Manager.list_webhooks(), expanded: nil)
         |> put_flash(:info, "Webhook deleted")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete webhook")}
    end
  end

  @impl true
  def handle_event("test_webhook", %{"id" => id}, socket) do
    case Repo.get(Webhook, String.to_integer(id)) do
      nil ->
        {:noreply, put_flash(socket, :error, "Webhook not found")}

      webhook ->
        test_payload = %{
          "event" => "webhook.test",
          "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "data" => %{"message" => "Test delivery from ClawdEx"}
        }

        case Manager.trigger("webhook.test", test_payload) do
          {:ok, _deliveries} ->
            socket =
              socket
              |> assign(webhooks: Manager.list_webhooks())
              |> put_flash(:info, "Test webhook sent to #{webhook.name}")

            socket =
              if socket.assigns.expanded == webhook.id do
                assign(socket, deliveries: load_deliveries(webhook.id))
              else
                socket
              end

            {:noreply, socket}

          _ ->
            {:noreply,
             socket
             |> put_flash(:error, "No matching webhooks for test event. Ensure 'webhook.test' is in the events list.")}
        end
    end
  end

  @impl true
  def handle_event("generate_secret", _params, socket) do
    secret = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    form = Map.put(socket.assigns.form, "secret", secret)
    {:noreply, assign(socket, form: form)}
  end

  defp load_deliveries(webhook_id) do
    from(d in Delivery,
      where: d.webhook_id == ^webhook_id,
      order_by: [desc: d.inserted_at],
      limit: 20
    )
    |> Repo.all()
  end

  defp default_form do
    %{
      "name" => "",
      "url" => "",
      "secret" => "",
      "events" => []
    }
  end

  defp status_color(true), do: "bg-green-500"
  defp status_color(false), do: "bg-gray-500"

  defp delivery_status_classes("success"), do: "bg-green-500/20 text-green-400"
  defp delivery_status_classes("pending"), do: "bg-yellow-500/20 text-yellow-400"
  defp delivery_status_classes("failed"), do: "bg-red-500/20 text-red-400"
  defp delivery_status_classes(_), do: "bg-gray-500/20 text-gray-400"

  defp format_datetime(nil), do: "Never"

  defp format_datetime(dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  end
end
