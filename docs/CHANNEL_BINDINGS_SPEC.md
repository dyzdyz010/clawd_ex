# Channel Bindings — Design Spec

## Overview

Replace the ad-hoc `default_topics` config with a first-class `channel_bindings` table. Each binding represents "this agent is permanently present in this channel location". On boot (or at runtime), each active binding auto-starts a persistent SessionWorker GenServer.

## Database

### New table: `channel_bindings`

```sql
CREATE TABLE channel_bindings (
  id BIGSERIAL PRIMARY KEY,
  agent_id BIGINT NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
  channel VARCHAR(50) NOT NULL,           -- "telegram", "discord", etc.
  channel_config JSONB NOT NULL DEFAULT '{}', -- channel-specific routing info
  session_key VARCHAR(255) NOT NULL,      -- auto-generated, unique
  active BOOLEAN NOT NULL DEFAULT true,
  inserted_at TIMESTAMP NOT NULL,
  updated_at TIMESTAMP NOT NULL,
  UNIQUE(session_key),
  UNIQUE(agent_id, channel, channel_config) -- no duplicate bindings
);
CREATE INDEX channel_bindings_agent_id_index ON channel_bindings(agent_id);
CREATE INDEX channel_bindings_active_index ON channel_bindings(active);
```

### channel_config examples

**Telegram:**
```json
{"chat_id": "-1003768565369", "topic_id": "144"}
```
or without topic:
```json
{"chat_id": "-1003768565369"}
```

**Discord (future):**
```json
{"guild_id": "123", "channel_id": "456"}
```

### session_key generation

Each channel module provides `build_session_key(agent_id, channel_config)`:

- Telegram with topic: `"telegram:{chat_id}:topic:{topic_id}:agent:{agent_id}"`
- Telegram without topic: `"telegram:{chat_id}:agent:{agent_id}"`
- Discord: `"discord:{guild_id}:{channel_id}:agent:{agent_id}"`

## Schema

```elixir
# lib/clawd_ex/channels/channel_binding.ex
defmodule ClawdEx.Channels.ChannelBinding do
  use Ecto.Schema
  import Ecto.Changeset

  schema "channel_bindings" do
    belongs_to :agent, ClawdEx.Agents.Agent
    field :channel, :string
    field :channel_config, :map, default: %{}
    field :session_key, :string
    field :active, :boolean, default: true
    timestamps(type: :utc_datetime)
  end

  def changeset(binding, attrs) do
    binding
    |> cast(attrs, [:agent_id, :channel, :channel_config, :session_key, :active])
    |> validate_required([:agent_id, :channel, :channel_config, :session_key])
    |> unique_constraint(:session_key)
    |> unique_constraint([:agent_id, :channel, :channel_config],
         name: :channel_bindings_agent_id_channel_channel_config_index)
  end
end
```

## Channel Behaviour Updates

Add to `ClawdEx.Channels.Channel`:

```elixir
@callback build_session_key(agent_id :: integer, channel_config :: map) :: String.t()
@callback deliver_message(channel_config :: map, content :: String.t(), opts :: keyword()) :: {:ok, term()} | {:error, term()}
```

### Telegram implementation:

```elixir
# In ClawdEx.Channels.Telegram
def build_session_key(agent_id, %{"chat_id" => chat_id, "topic_id" => topic_id}) do
  "telegram:#{chat_id}:topic:#{topic_id}:agent:#{agent_id}"
end
def build_session_key(agent_id, %{"chat_id" => chat_id}) do
  "telegram:#{chat_id}:agent:#{agent_id}"
end

def deliver_message(%{"chat_id" => chat_id} = config, content, opts) do
  topic_id = Map.get(config, "topic_id")
  opts = if topic_id, do: Keyword.put(opts, :message_thread_id, topic_id), else: opts
  send_message(chat_id, content, opts)
end
```

## agents.json Format Update

```json
{
  "name": "CTO",
  "default_model": "anthropic/claude-opus-4-6",
  "capabilities": ["architecture", "code-review"],
  "channel_bindings": [
    {"channel": "telegram", "chat_id": "-1003768565369", "topic_id": "144"}
  ],
  "active": true,
  "auto_start": true,
  "always_on": true
}
```

The old `config.default_topics` field is **removed**. Migration: Seeder reads `channel_bindings` array and syncs to the table.

## AutoStarter Changes

Current flow:
```
boot → for each auto_start agent → start "agent:{name}:always_on" session
```

New flow:
```
boot
  → AgentSeeder.sync! (includes channel_bindings sync)
  → for each auto_start agent:
      → query channel_bindings where agent_id = X and active = true
      → for each binding:
          → SessionManager.start_session(
              session_key: binding.session_key,
              agent_id: binding.agent_id,
              channel: binding.channel,
              channel_config: binding.channel_config
            )
      → if agent has no bindings, start "agent:{name}:always_on" as fallback
         (so A2A registration still works for agents not bound to any channel)
  → health check covers all binding sessions
```

## SessionWorker Changes

Add `channel_config` to state:

```elixir
defstruct [
  # ... existing fields ...
  :channel_config,  # NEW: %{"chat_id" => "...", "topic_id" => "..."}
]
```

### Heartbeat delivery

When heartbeat produces a non-OK response and the session has channel + channel_config:

```elixir
defp deliver_heartbeat_alert(state, response) do
  if state.channel != "system" and state.channel_config do
    # Look up the channel module
    case ClawdEx.Channels.Registry.get_channel(state.channel) do
      {:ok, module} ->
        module.deliver_message(state.channel_config, response, [])
      _ ->
        # Fallback: just broadcast via PubSub
        broadcast_heartbeat_alert(state, response)
    end
  else
    broadcast_heartbeat_alert(state, response)
  end
end
```

## SessionManager Changes

`start_session/1` opts now support `:channel_config`:

```elixir
def start_session(opts) when is_list(opts) do
  # ... existing find_session logic ...
  # Pass channel_config through to SessionWorker
end
```

## Seeder Changes

After upserting agent, sync channel_bindings:

```elixir
defp sync_channel_bindings(agent, definition) do
  bindings_def = Map.get(definition, "channel_bindings", [])
  
  # Build expected bindings
  expected = Enum.map(bindings_def, fn b ->
    channel = Map.fetch!(b, "channel")
    config = Map.drop(b, ["channel"])
    channel_module = ClawdEx.Channels.Registry.get_channel_module(channel)
    session_key = channel_module.build_session_key(agent.id, config)
    %{channel: channel, channel_config: config, session_key: session_key}
  end)
  
  # Get current bindings from DB
  current = Repo.all(from cb in ChannelBinding, where: cb.agent_id == ^agent.id)
  
  # Create missing, deactivate removed
  # ...
end
```

## Telegram handle_message Changes

When a message comes in:
1. `resolve_agent_for_group` — unchanged
2. `build_group_session_key` — unchanged (still builds the same format)
3. `SessionManager.start_session` — finds the already-running GenServer from boot ✓

No major changes needed. The session_key format is identical.

## New Tools (Agent Self-Management)

### channel_bind

Agent can bind itself to a channel location:

```
Tool: channel_bind
Params: {channel: "telegram", chat_id: "-100xxx", topic_id: "55"}
Result: "Bound to telegram:-100xxx:topic:55 — session started"
```

### channel_unbind

```
Tool: channel_unbind
Params: {channel: "telegram", chat_id: "-100xxx", topic_id: "55"}
Result: "Unbound from telegram:-100xxx:topic:55 — session stopped"
```

### channel_bindings_list

```
Tool: channel_bindings_list
Params: {}  (lists own bindings)
Result: [{channel: "telegram", config: {...}, active: true, session_key: "..."}]
```

## Migration Plan

1. Create `channel_bindings` table
2. Migrate existing `config.default_topics` data to channel_bindings
3. Update Seeder to handle `channel_bindings` in agents.json
4. Update agents.json to new format
5. Update AutoStarter to use bindings
6. Add channel callbacks
7. Update SessionWorker for channel_config + heartbeat delivery
8. Add tools
9. Remove old `default_topics` code paths
10. Tests

## Test Plan

### Unit Tests
- ChannelBinding schema/changeset validation
- build_session_key for Telegram (with/without topic)
- Seeder sync_channel_bindings (create, update, deactivate)
- deliver_message routing

### Integration Tests
- AutoStarter boots → all binding sessions running
- Telegram message hits pre-started session (no cold start)
- Health check detects and restarts dead binding session
- channel_bind tool creates binding + starts session
- channel_unbind tool deactivates binding + stops session

### End-to-End Tests (with LLM)
- Boot system → send message to Telegram topic → agent responds (session was pre-started)
- Agent uses channel_bind tool → verify new session created → send message → get response
- Heartbeat triggers → non-OK response → message appears in Telegram topic
- System restart → all sessions recover → messages still work

## File Changes Summary

### New Files
- `priv/repo/migrations/XXX_create_channel_bindings.exs`
- `lib/clawd_ex/channels/channel_binding.ex` (schema)
- `lib/clawd_ex/channels/binding_manager.ex` (CRUD + session lifecycle)
- `lib/clawd_ex/tools/channel_bind.ex`
- `lib/clawd_ex/tools/channel_unbind.ex`
- `lib/clawd_ex/tools/channel_bindings_list.ex`
- `test/clawd_ex/channels/channel_binding_test.exs`
- `test/clawd_ex/channels/binding_manager_test.exs`
- `test/clawd_ex/agent/auto_starter_test.exs` (update)

### Modified Files
- `priv/agents.json` — new format with channel_bindings
- `lib/clawd_ex/channels/channel.ex` — add callbacks
- `lib/clawd_ex/channels/telegram.ex` — implement callbacks, remove default_topics logic
- `lib/clawd_ex/agent/auto_starter.ex` — use bindings instead of agent:xxx:always_on
- `lib/clawd_ex/agents/seeder.ex` — sync channel_bindings
- `lib/clawd_ex/sessions/session_worker.ex` — channel_config in state, heartbeat delivery
- `lib/clawd_ex/sessions/session_manager.ex` — pass channel_config
- `lib/clawd_ex/tools/registry.ex` — register new tools
