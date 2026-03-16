defmodule ClawdEx.Webhooks.Manager do
  @moduledoc """
  Webhook 管理器 — 注册 webhook、触发事件、定期重试失败投递。
  """
  use GenServer

  require Logger

  import Ecto.Query

  alias ClawdEx.Webhooks.{Webhook, Delivery, Dispatcher}
  alias ClawdEx.Repo

  @retry_interval_ms 60_000

  # ============================================================================
  # Client API
  # ============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Register a new webhook"
  @spec register_webhook(map()) :: {:ok, Webhook.t()} | {:error, Ecto.Changeset.t()}
  def register_webhook(attrs) do
    attrs = maybe_generate_secret(attrs)

    %Webhook{}
    |> Webhook.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Update an existing webhook"
  @spec update_webhook(integer(), map()) :: {:ok, Webhook.t()} | {:error, term()}
  def update_webhook(webhook_id, attrs) do
    case Repo.get(Webhook, webhook_id) do
      nil -> {:error, :not_found}
      webhook -> webhook |> Webhook.changeset(attrs) |> Repo.update()
    end
  end

  @doc "Delete a webhook"
  @spec delete_webhook(integer()) :: {:ok, Webhook.t()} | {:error, term()}
  def delete_webhook(webhook_id) do
    case Repo.get(Webhook, webhook_id) do
      nil -> {:error, :not_found}
      webhook -> Repo.delete(webhook)
    end
  end

  @doc "List all webhooks"
  @spec list_webhooks(keyword()) :: [Webhook.t()]
  def list_webhooks(opts \\ []) do
    query = from(w in Webhook, order_by: [asc: w.name])

    query =
      if Keyword.get(opts, :enabled_only, false),
        do: from(w in query, where: w.enabled == true),
        else: query

    Repo.all(query)
  end

  @doc "Trigger an event — find matching webhooks, create deliveries, dispatch"
  @spec trigger(String.t(), map()) :: {:ok, [Delivery.t()]}
  def trigger(event_type, payload) do
    webhooks =
      from(w in Webhook,
        where: w.enabled == true and ^event_type in w.events
      )
      |> Repo.all()

    deliveries =
      Enum.map(webhooks, fn webhook ->
        {:ok, delivery} =
          %Delivery{}
          |> Delivery.changeset(%{
            webhook_id: webhook.id,
            event_type: event_type,
            payload: payload
          })
          |> Repo.insert()

        # Dispatch async
        Dispatcher.deliver_async(webhook, delivery)

        # Update webhook stats
        webhook
        |> Webhook.changeset(%{
          last_triggered_at: DateTime.utc_now(),
          retry_count: webhook.retry_count + 1
        })
        |> Repo.update()

        delivery
      end)

    {:ok, deliveries}
  end

  @doc "Retry all failed deliveries that are due"
  @spec retry_failed() :: :ok
  def retry_failed do
    GenServer.cast(__MODULE__, :retry_failed)
  end

  # ============================================================================
  # Signature
  # ============================================================================

  @doc "Generate HMAC-SHA256 signature for a payload"
  @spec sign(String.t(), String.t()) :: String.t()
  def sign(payload_json, secret) do
    :crypto.mac(:hmac, :sha256, secret, payload_json)
    |> Base.encode16(case: :lower)
  end

  @doc "Verify HMAC-SHA256 signature"
  @spec verify_signature(String.t(), String.t(), String.t()) :: boolean()
  def verify_signature(payload_json, secret, signature) do
    expected = sign(payload_json, secret)
    Plug.Crypto.secure_compare(expected, signature)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    schedule_retry()
    {:ok, %{}}
  end

  @impl true
  def handle_cast(:retry_failed, state) do
    do_retry_failed()
    {:noreply, state}
  end

  @impl true
  def handle_info(:retry_failed, state) do
    do_retry_failed()
    schedule_retry()
    {:noreply, state}
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp schedule_retry do
    Process.send_after(self(), :retry_failed, @retry_interval_ms)
  end

  defp do_retry_failed do
    now = DateTime.utc_now()

    deliveries =
      from(d in Delivery,
        where: d.status == "failed" and d.attempts < 5,
        where: is_nil(d.next_retry_at) or d.next_retry_at <= ^now,
        preload: [:webhook]
      )
      |> Repo.all()

    if length(deliveries) > 0 do
      Logger.info("Retrying #{length(deliveries)} failed webhook deliveries")
    end

    Enum.each(deliveries, fn delivery ->
      Dispatcher.deliver_async(delivery.webhook, delivery)
    end)
  end

  defp maybe_generate_secret(attrs) do
    has_secret =
      Map.has_key?(attrs, :secret) or Map.has_key?(attrs, "secret")

    if has_secret do
      attrs
    else
      secret = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
      Map.put(attrs, :secret, secret)
    end
  end
end
