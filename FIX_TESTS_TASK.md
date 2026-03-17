# Task: Fix 106 Test Failures

## Current: 556 tests, 106 failures

## Failure Summary

| Test File | Failures | Root Cause |
|-----------|----------|------------|
| test/clawd_ex/tasks/manager_test.exs | 25 | Repo not started in sandbox |
| test/clawd_ex/tools/a2a_test.exs | 22 | Repo + A2AMailboxRegistry not started |
| test/clawd_ex/tools/sessions_spawn_test.exs | 18 | Repo not started |
| test/clawd_ex/a2a/router_test.exs | 17 | Repo not started |
| test/clawd_ex/a2a/mailbox_test.exs | 13 | Registry not started (10), Repo (3) |
| test/clawd_ex/agent/loop_test.exs | 2 | Missing GenServer deps |
| test/clawd_ex/tools/tools_test.exs | 1 | macOS /var vs /private/var path |
| test/clawd_ex/browser/server_test.exs | 1 | Chrome not available |

## Fix Instructions

### A2A MailboxTest (10 registry errors)
Add to setup:
```elixir
start_supervised!({Registry, keys: :unique, name: ClawdEx.A2AMailboxRegistry})
start_supervised!({DynamicSupervisor, name: ClawdEx.A2AMailboxSupervisor, strategy: :one_for_one})
```
Also ensure Phoenix.PubSub is started if needed.

### DataCase tests (Repo sandbox failures)
The error is "could not lookup Ecto repo ClawdEx.Repo because it was not started".
Check if test modules properly `use ClawdEx.DataCase`. If they do, the app may not be starting Repo correctly in test env. Check if Application supervision tree starts correctly.

### Tools.ToolsTest path issue
macOS: /var is symlink to /private/var. Use `Path.expand/1` or compare with `File.cwd!()` based approach.

### Browser.ServerTest
Add `@moduletag :requires_chrome` and add `ExUnit.configure(exclude: [:requires_chrome])` to test_helper.exs.

## Rules
- Only modify test files and test/support/
- Do NOT change business logic
- Use `start_supervised!/1` for test dependencies
- Run `mix test` after fixes to verify
