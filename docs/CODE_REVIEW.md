# ClawdEx Architecture Review

## Scope

Reviewed:

- `lib/clawd_ex/agent/output_manager.ex`
- `lib/clawd_ex/agent/loop.ex`
- `lib/clawd_ex/tasks/task.ex`
- `lib/clawd_ex/tasks/manager.ex`
- `lib/clawd_ex/a2a/message.ex`
- `lib/clawd_ex/a2a/router.ex`
- `lib/clawd_ex/a2a/mailbox.ex`
- `lib/clawd_ex/webhooks/manager.ex`
- `lib/clawd_ex/webhooks/webhook.ex`
- `lib/clawd_ex/webhooks/dispatcher.ex`
- `lib/clawd_ex/webhooks/delivery.ex`
- `lib/clawd_ex/security/tool_guard.ex`
- `lib/clawd_ex/security/exec_sandbox.ex`
- `lib/clawd_ex/application.ex`

I also looked at adjacent integration points where the reviewed modules depend on them, especially `lib/clawd_ex/tools/a2a.ex`, `lib/clawd_ex/tools/task_tool.ex`, `lib/clawd_ex/tools/registry.ex`, `lib/clawd_ex/sessions/session_manager.ex`, `lib/clawd_ex/sessions/session_worker.ex`, `lib/clawd_ex/skills/*.ex`, and the new migrations for tasks/A2A/webhooks.

Attempted validation with `mix compile`, but Mix could not start in this sandbox because `Mix.PubSub` was denied TCP socket creation (`:eperm`). The findings below are therefore based on code review, not a successful compile/test run.

## Executive Summary

The codebase has a promising shape: the major subsystems are conceptually separated into agent execution, persistent tasks, A2A messaging, outbound webhooks, and security gating. The problems are not at the idea level; they are at the reliability boundary. Several modules implement distributed or asynchronous features with local in-memory state, fire-and-forget tasks, and non-atomic persistence. That combination creates hidden at-most-once behavior, duplicate delivery, stranded work, and timeout paths that can crash the very process that is supposed to coordinate recovery.

The largest architectural issues are:

1. A2A delivery/ack/request semantics are internally inconsistent.
2. `ClawdEx.Agent.Loop` uses unmanaged background work and has crash paths on async runs.
3. Task and webhook lifecycle changes are not concurrency-safe or claim-based.
4. Security enforcement is parameter rewriting, not an authoritative sandbox boundary.
5. Several reviewed modules assume a single-node runtime, while the application tree already hints at clustered operation via `DNSCluster`.

## Module Scores

| Module | Score | Notes |
| --- | --- | --- |
| `ClawdEx.Agent.OutputManager` | 4/10 | Simple API, but no durability, cleanup on abnormal termination, or replay semantics. |
| `ClawdEx.Agent.Loop` | 4/10 | State-machine choice is good; async orchestration and failure handling are not production-safe. |
| `ClawdEx.Tasks.Task` | 5/10 | Reasonable base schema, but invariants live only in changesets and not in the data model. |
| `ClawdEx.Tasks.Manager` | 4/10 | Useful lifecycle surface, but updates are not atomic and the scheduler is single-node/local-state biased. |
| `ClawdEx.A2A.Message` | 5/10 | Minimal schema is clear, but it does not encode request/response invariants or durable delivery state. |
| `ClawdEx.A2A.Router` | 3/10 | Too many responsibilities in one GenServer; delivery semantics are optimistic and local-only. |
| `ClawdEx.A2A.Mailbox` | 3/10 | Queue abstraction exists, but ack/recovery semantics are broken and not durable. |
| `ClawdEx.Webhooks.Webhook` | 5/10 | Fine as a registration schema, but validation and secret handling are shallow. |
| `ClawdEx.Webhooks.Delivery` | 4/10 | Missing delivery-state transitions needed for claiming, dedupe, and safe retries. |
| `ClawdEx.Webhooks.Dispatcher` | 4/10 | Straightforward sender, but task supervision, claiming, and update safety are weak. |
| `ClawdEx.Webhooks.Manager` | 4/10 | Good service boundary, but fan-out is not transactional and retries are race-prone. |
| `ClawdEx.Security.ToolGuard` | 5/10 | Decent policy skeleton, but it trusts caller-normalized context and has no authoritative approval state. |
| `ClawdEx.Security.ExecSandbox` | 3/10 | Not a true sandbox; path checks, key normalization, and output limiting are unsafe. |
| `ClawdEx.Application` | 5/10 | Sensible child inventory, but startup side effects and local-only managers reduce operability. |

## Findings

### High

1. A2A mailbox consumption is broken at the contract level. `ClawdEx.Agent.Loop` acknowledges A2A work immediately in `idle/3` before the run has even started (`lib/clawd_ex/agent/loop.ex:213-239`), but it never calls `A2AMailbox.pop/1`. `ClawdEx.A2A.Mailbox.ack/2` only removes entries from the `processing` map (`lib/clawd_ex/a2a/mailbox.ex:133-138`), while `peek/1` leaves the message at the head of `inbox` (`lib/clawd_ex/a2a/mailbox.ex:106-121`). The same message can therefore be scheduled repeatedly every time the loop returns to `:idle`, and the ack happens before success is known. This is both duplicate-processing prone and still not reliable.

2. A2A delivery is marked as successful before there is a durable receiver. `ClawdEx.A2A.Router.deliver_to_agent/1` broadcasts on PubSub and immediately updates the DB row to `"delivered"` (`lib/clawd_ex/a2a/router.ex:302-321`). But mailbox processes are dynamic and opt-in (`lib/clawd_ex/a2a/mailbox.ex:25-36`), and no reviewed code path ensures they are started before sending. There is also no usage of `ClawdEx.A2A.Router.register/2` anywhere in the codebase. In practice, an A2A message can be marked delivered even when no mailbox exists and no consumer is listening.

3. Sync A2A requests are not wired to the execution path that receives them. The router expects a response via `respond/4` and keeps waiters in `pending_requests` (`lib/clawd_ex/a2a/router.ex:157-223`), but the agent loop formats incoming requests as prompts instructing the agent to reply using the `a2a` tool with action `"send"` (`lib/clawd_ex/agent/loop.ex:854-862`). The current `a2a` tool exposes `"discover"`, `"send"`, `"request"`, and `"delegate"`, but not `"respond"` (`lib/clawd_ex/tools/a2a.ex:32-36`, `lib/clawd_ex/tools/a2a.ex:82-87`). The net effect is that the nominal request/response API will time out even when the receiving agent follows the prompt exactly.

4. A2A-initiated agent runs can crash on normal error paths. Async A2A runs set `reply_to: nil` (`lib/clawd_ex/agent/loop.ex:230-239`), but `reply_error/3` always calls `GenStateMachine.reply/2` unconditionally (`lib/clawd_ex/agent/loop.ex:713-716`). Any timeout, cancel, or AI/tool error during an A2A-initiated run turns into a process crash instead of a clean async failure.

5. `ClawdEx.Agent.Loop` uses unmanaged background tasks for the most important work. AI inference uses `Task.start/1` (`lib/clawd_ex/agent/loop.ex:311-330`) and tool execution uses another `Task.start/1` plus `Task.async_stream/3` (`lib/clawd_ex/agent/loop.ex:424-472`). The loop does not keep task pids/refs, does not monitor them, and does not cancel them on stop or timeout. A timed-out run can continue consuming model tokens, calling tools, and broadcasting stale tool events after the state machine has already gone back to `:idle`.

6. Task lifecycle updates are not concurrency-safe. `ClawdEx.Tasks.Task` has no optimistic lock and no DB-level transition protection (`lib/clawd_ex/tasks/task.ex:16-52`). `ClawdEx.Tasks.Manager.update_task/2` does a `Repo.get` followed by `Repo.update` (`lib/clawd_ex/tasks/manager.ex:63-92`), and `requeue_task/1` updates a stale struct directly (`lib/clawd_ex/tasks/manager.ex:257-279`). Concurrent calls to `start_task/1`, `complete_task/2`, `fail_task/2`, `heartbeat/1`, auto-assignment, and requeueing can overwrite one another or revive already-finished work.

7. Webhook retries are race-prone and can permanently strand deliveries. `ClawdEx.Webhooks.Manager.do_retry_failed/0` selects due failed rows and immediately spawns async work (`lib/clawd_ex/webhooks/manager.ex:157-175`), but `ClawdEx.Webhooks.Delivery` has no claim state such as `"dispatching"` (`lib/clawd_ex/webhooks/delivery.ex:10-35`). Two sweeps can send the same delivery concurrently. Separately, `Dispatcher.deliver_async/2` ignores the return value of `Task.Supervisor.start_child/2` (`lib/clawd_ex/webhooks/dispatcher.ex:18-25`), so a spawn failure or worker crash can leave a row stuck in `"pending"` forever because the retry loop only picks `"failed"` rows (`lib/clawd_ex/webhooks/manager.ex:160-166`).

### Medium

8. `OutputManager` only works while its ephemeral registration is intact. Missing registrations fall back to `output:run:{run_id}` for segments (`lib/clawd_ex/agent/output_manager.ex:89-105`, `lib/clawd_ex/agent/output_manager.ex:141-154`), which is not the documented subscription topic. Missing registrations drop completion events entirely (`lib/clawd_ex/agent/output_manager.ex:119-134`). There is also no timeout-based cleanup for runs that fail or crash before `deliver_complete/3`, so `state.runs` can leak memory.

9. `OutputManager` also accumulates segments with `++` on every delivery (`lib/clawd_ex/agent/output_manager.ex:98-103`). That is O(n) per append and duplicates segment data into both `segments` and `delivered`, even though neither list is currently used for replay. Under long tool-heavy runs this is unnecessary memory churn in a single GenServer.

10. The task scheduler is vulnerable to stuck and duplicate assignments. It only reaps `"running"` tasks (`lib/clawd_ex/tasks/manager.ex:175-217`) and only auto-assigns `"pending"` tasks (`lib/clawd_ex/tasks/manager.ex:219-254`), so an agent dying after `assign_task/3` but before `start_task/1` leaves the task stranded in `"assigned"`. Auto-assignment itself is a read-then-update sequence with no claim condition, so multiple schedulers or nodes can assign the same task concurrently.

11. Several reviewed GenServers perform blocking DB work in callbacks. The router does inserts, queries, and updates directly in `handle_call/3` and `handle_cast/2` (`lib/clawd_ex/a2a/router.ex:131-223`, `lib/clawd_ex/a2a/router.ex:252-260`, `lib/clawd_ex/a2a/router.ex:289-346`). The task manager’s periodic loop runs DB scans and updates in `handle_info/2` (`lib/clawd_ex/tasks/manager.ex:159-279`). The webhook manager also scans and dispatches in its GenServer (`lib/clawd_ex/webhooks/manager.ex:137-175`). This is an OTP anti-pattern when the same process is also expected to remain responsive for routing and scheduling decisions.

12. The data model does not encode several lifecycle invariants that the modules depend on. Examples:

- `tasks.status`, `priority`, `retry_count`, and `timeout_seconds` have no DB check constraints (`lib/clawd_ex/tasks/task.ex:44-52`, `priv/repo/migrations/20260316100000_create_tasks.exs:5-31`).
- `a2a_messages.content` is required in the changeset but nullable in the migration (`lib/clawd_ex/a2a/message.ex:40-52`, `priv/repo/migrations/20260316100001_create_a2a_messages.exs:5-26`).
- `webhook_deliveries` has no state for claimed/in-flight work, which the retry architecture needs (`lib/clawd_ex/webhooks/delivery.ex:10-35`, `priv/repo/migrations/20260316100002_create_webhooks.exs:21-37`).

13. Error handling relies on exceptions and ignored return values. Important examples:

- `save_message/4` uses `Repo.insert!()` inside the agent loop (`lib/clawd_ex/agent/loop.ex:593-606`).
- Tool-result formatting uses `Jason.encode!()` on arbitrary tool outputs (`lib/clawd_ex/agent/loop.ex:672-674`).
- Webhook trigger fan-out pattern matches successful inserts and can crash its caller on one bad insert after earlier fan-out has already started (`lib/clawd_ex/webhooks/manager.ex:74-99`).
- `deliver_to_agent/1`, `auto_assign_pending_tasks/0`, and `requeue_task/1` ignore `Repo.update/1` results (`lib/clawd_ex/a2a/router.ex:317-320`, `lib/clawd_ex/tasks/manager.ex:242-245`, `lib/clawd_ex/tasks/manager.ex:263-279`).

14. Security enforcement is transport-dependent rather than authoritative. `ToolGuard` expects the caller to provide normalized tool names and atom-keyed context (`lib/clawd_ex/security/tool_guard.ex:15-20`, `lib/clawd_ex/security/tool_guard.ex:27-40`, `lib/clawd_ex/security/tool_guard.ex:109-135`). `ExecSandbox` reads both atom and string keys but only writes sanitized values back under string keys (`lib/clawd_ex/security/exec_sandbox.ex:47-99`), so downstream code that still reads atom keys can bypass the rewritten `workdir`, `timeout`, `env`, or `command`.

15. `ExecSandbox` is not a secure containment boundary. Workdir checks use `String.starts_with?/2` on expanded paths (`lib/clawd_ex/security/exec_sandbox.ex:52-59`), which allows sibling-prefix escapes such as `/allowed_dir_evil`, and does not resolve symlinks. Output limiting wraps the command in `(... ) | head -c ...` (`lib/clawd_ex/security/exec_sandbox.ex:92-99`), which changes exit-code semantics and only caps stdout, not stderr. This module is better described as parameter sanitization than sandboxing.

16. The application supervision tree is built as if everything is local and always-on. `init_workspace/0` runs before supervision and only logs warnings on failure (`lib/clawd_ex/application.ex:11-14`, `lib/clawd_ex/application.ex:69-86`). Meanwhile, the app starts DNS clustering (`lib/clawd_ex/application.ex:17`) but the reviewed coordination modules still depend on local registries, local session lookup, and in-memory pending-request state. The result is a cluster-shaped topology with single-node semantics.

### Low

17. There is a noticeable amount of design drift:

- `ClawdEx.Agent.Loop` defines a `:streaming` state that is never used (`lib/clawd_ex/agent/loop.ex:52`).
- `output_manager_pid` exists in loop state but is never populated with a pid (`lib/clawd_ex/agent/loop.ex:48-49`, `lib/clawd_ex/agent/loop.ex:125-136`).
- `Webhook.retry_count` is incremented on every trigger, not on actual retries (`lib/clawd_ex/webhooks/manager.ex:88-95`), so the field name is misleading.

18. `load_session_messages/1` retrieves the oldest 100 messages, not the latest 100 (`lib/clawd_ex/agent/loop.ex:566-573`). Over time, the agent context will skew toward the beginning of the conversation instead of the most recent turns.

## OTP Anti-Patterns

- Unmanaged `Task.start/1` for long-lived or cancelable work in `ClawdEx.Agent.Loop`.
- Single GenServers doing synchronous Repo work on hot paths in `ClawdEx.A2A.Router`, `ClawdEx.Tasks.Manager`, and `ClawdEx.Webhooks.Manager`.
- Side effects before supervision in `ClawdEx.Application.start/2`.
- Local in-memory registries and wait maps used for semantics that are described as delivery/routing guarantees.
- Queue ack semantics implemented partly in memory and partly in the DB, without a single owner of state transitions.

## Missing Error Handling

- No safe fallback when message persistence fails in the loop.
- No safe fallback when webhook delivery insert/update fails during fan-out.
- No handling for non-timeout task exits in tool `async_stream`.
- No mailbox recovery path after consumer crash or mailbox restart.
- No explicit error when `respond/4` is called for a nonexistent `reply_to`; the system persists an orphaned response instead.

## Integration Gaps

1. A2A and agent execution do not agree on how replies are supposed to work.
2. A2A routing and mailboxes do not agree on who owns delivery guarantees.
3. Task lifecycle and session lifecycle are only loosely connected through `session_key`, with no cluster-aware liveness or transition ownership.
4. Webhook fan-out is synchronous from task/A2A/agent code paths, so observability features can fail or delay core workflows.
5. Security modules expect richer execution context than `ClawdEx.Agent.Loop.execute_tool/2` currently passes. The loop only provides `session_id`, `agent_id`, and `run_id` (`lib/clawd_ex/agent/loop.ex:633-637`), while tools and security features also depend on `session_key`, workspace, allow/deny lists, approval state, and allowed directories (`lib/clawd_ex/tools/task_tool.ex:110-123`, `lib/clawd_ex/security/exec_sandbox.ex:47-50`, `lib/clawd_ex/security/tool_guard.ex:27-40`).

## Prioritized Improvements

1. Fix A2A semantics first. Make mailbox consumption durable and explicit: `pop` before processing, `ack` only on success, and requeue/recover unacked work on crash or timeout. Ensure mailboxes are started before routing and treat PubSub as notification, not proof of delivery.
2. Replace `Task.start/1` in `ClawdEx.Agent.Loop` with supervised, monitored tasks and explicit cancellation on stop/timeout. Keep refs in state and ignore only ref-matched stale completions.
3. Introduce atomic lifecycle transitions for tasks and webhook deliveries. Use `Repo.transaction/1` or `Ecto.Multi`, `update_all` with `where` clauses on the old state, and optimistic locking where appropriate.
4. Separate routing/scheduling state from blocking persistence. Use a fast coordination process plus dedicated worker/supervisor pipelines for DB and external I/O.
5. Redesign A2A request/response around a single contract. Either expose a `respond` action in the tool layer or change the router to correlate reply messages sent through the normal mailbox path.
6. Rework webhook delivery into a claimed state machine: `pending -> dispatching -> success | failed`, with retry claims and idempotency keys.
7. Tighten the security boundary. Canonicalize params/context once, use real path containment checks, and stop calling the current command wrapper a sandbox unless it enforces process-level isolation.
8. Add DB constraints for enum/status/positive-number invariants and align migrations with the changeset requirements.
9. Make application boot profiles explicit. CLI/status/health paths should not need the full browser/channel runtime, and workspace initialization should be supervised or fatal.
10. Trim design drift and misleading fields so the code reflects the actual runtime behavior.
