defmodule ClawdEx.Automation.CronJob do
  @moduledoc """
  定时任务模型
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "cron_jobs" do
    field :name, :string
    field :description, :string
    field :schedule, :string
    field :command, :string
    # Alias for command - for tool compatibility
    field :text, :string, virtual: true
    field :agent_id, :string
    field :enabled, :boolean, default: true
    field :timezone, :string, default: "UTC"
    field :last_run_at, :utc_datetime_usec
    field :next_run_at, :utc_datetime_usec
    field :run_count, :integer, default: 0
    field :metadata, :map, default: %{}

    # Payload type: "system_event" or "agent_turn"
    field :payload_type, :string, default: "system_event"
    # Target channel for results (telegram/discord/webchat)
    field :target_channel, :string
    # Target session key for system_event mode
    field :session_key, :string
    # Cleanup strategy for agent_turn: "delete" or "keep"
    field :cleanup, :string, default: "delete"
    # Timeout in seconds
    field :timeout_seconds, :integer, default: 300

    # Notification targets: list of %{channel, target, auto}
    # e.g., [%{channel: "telegram", target: "123456", auto: true}]
    field :notify, {:array, :map}, default: []
    # Dedicated session key for storing results (especially for webchat)
    field :result_session_key, :string

    has_many :runs, ClawdEx.Automation.CronJobRun, foreign_key: :job_id

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(cron_job, attrs) do
    # Handle text as alias for command
    attrs =
      if Map.has_key?(attrs, "text") || Map.has_key?(attrs, :text) do
        text = Map.get(attrs, "text") || Map.get(attrs, :text)
        Map.put(attrs, :command, text)
      else
        attrs
      end

    cron_job
    |> cast(attrs, [
      :name,
      :description,
      :schedule,
      :command,
      :agent_id,
      :enabled,
      :timezone,
      :last_run_at,
      :next_run_at,
      :run_count,
      :metadata,
      :payload_type,
      :target_channel,
      :session_key,
      :cleanup,
      :timeout_seconds,
      :notify,
      :result_session_key
    ])
    |> validate_required([:name, :schedule, :command])
    |> validate_inclusion(:payload_type, ["system_event", "agent_turn"])
    |> validate_inclusion(:cleanup, ["delete", "keep"])
    |> maybe_set_next_run()
  end

  defp maybe_set_next_run(changeset) do
    case get_change(changeset, :schedule) do
      nil ->
        changeset

      _schedule ->
        # Calculate next run from schedule
        # For now, just set to 1 hour from now as placeholder
        next_run = DateTime.utc_now() |> DateTime.add(3600, :second)
        put_change(changeset, :next_run_at, next_run)
    end
  end
end
