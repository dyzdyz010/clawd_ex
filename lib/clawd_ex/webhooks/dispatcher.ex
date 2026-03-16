defmodule ClawdEx.Webhooks.Dispatcher do
  @moduledoc """
  Webhook HTTP 投递 — 异步 HTTP 请求 + 指数退避重试。

  Backoff schedule: 1s, 5s, 30s, 5min, 30min (max 5 retries)
  """

  require Logger

  alias ClawdEx.Webhooks.{Webhook, Delivery, Manager}
  alias ClawdEx.Repo

  @max_retries 5
  @backoff_schedule [1, 5, 30, 300, 1800]

  @doc "Deliver a webhook payload asynchronously"
  @spec deliver_async(Webhook.t(), Delivery.t()) :: :ok
  def deliver_async(%Webhook{} = webhook, %Delivery{} = delivery) do
    Task.Supervisor.start_child(
      ClawdEx.WebhookTaskSupervisor,
      fn -> deliver(webhook, delivery) end
    )

    :ok
  end

  @doc "Deliver a webhook payload synchronously (used in tests and retries)"
  @spec deliver(Webhook.t(), Delivery.t()) :: {:ok, Delivery.t()} | {:error, Delivery.t()}
  def deliver(%Webhook{} = webhook, %Delivery{} = delivery) do
    payload_json = Jason.encode!(delivery.payload)
    signature = Manager.sign(payload_json, webhook.secret)

    headers =
      Map.merge(webhook.headers || %{}, %{
        "content-type" => "application/json",
        "x-webhook-signature" => signature,
        "x-webhook-event" => delivery.event_type,
        "x-webhook-delivery-id" => to_string(delivery.id)
      })

    header_list = Enum.map(headers, fn {k, v} -> {k, v} end)

    case Req.post(webhook.url, body: payload_json, headers: header_list, receive_timeout: 15_000) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        {:ok, updated} = mark_success(delivery, status)
        Logger.debug("Webhook #{webhook.name} delivered: HTTP #{status}")
        {:ok, updated}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.warning("Webhook #{webhook.name} failed: HTTP #{status}")
        {:error, mark_failed(delivery, status, truncate(body))}

      {:error, reason} ->
        Logger.warning("Webhook #{webhook.name} delivery error: #{inspect(reason)}")
        {:error, mark_failed(delivery, nil, inspect(reason))}
    end
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp mark_success(delivery, status_code) do
    delivery
    |> Delivery.changeset(%{
      status: "success",
      response_code: status_code,
      attempts: delivery.attempts + 1,
      next_retry_at: nil
    })
    |> Repo.update()
  end

  defp mark_failed(delivery, status_code, response_body) do
    new_attempts = delivery.attempts + 1

    attrs = %{
      attempts: new_attempts,
      response_code: status_code,
      response_body: response_body
    }

    attrs =
      if new_attempts >= @max_retries do
        Map.put(attrs, :status, "failed")
      else
        backoff_seconds = Enum.at(@backoff_schedule, new_attempts - 1, 1800)
        next_retry = DateTime.add(DateTime.utc_now(), backoff_seconds, :second)

        attrs
        |> Map.put(:status, "failed")
        |> Map.put(:next_retry_at, next_retry)
      end

    {:ok, updated} =
      delivery
      |> Delivery.changeset(attrs)
      |> Repo.update()

    updated
  end

  defp truncate(body) when is_binary(body) do
    if String.length(body) > 4000 do
      String.slice(body, 0, 4000) <> "...(truncated)"
    else
      body
    end
  end

  defp truncate(body), do: inspect(body) |> truncate()
end
