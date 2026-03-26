# RFC: Agent Always-On — OTP 常驻 Session

> 所有 active agent 默认常驻 session，由 OTP supervision 保活，
> 零 LLM heartbeat 开销，A2A 随时可通信。

## 目标

让所有 11 个 agent 在系统启动时自动创建 session，常驻在内存中：
- **零 API 开销** — 不调 LLM heartbeat，只有收到消息时才调 AI
- **OTP 监督** — crash 自动重启，不需要 LLM 检测存活
- **A2A 就绪** — session 启动时自动注册到 A2A Router，随时可通信
- **轻量级** — 每个 session = 1 个 SessionWorker GenServer + 1 个 AgentLoop GenStateMachine，内存 < 1MB

## 现有机制分析

已经有的：
1. `AutoStarter` GenServer — 启动时查 `auto_start: true` 的 agent，启动 session
2. `SessionManager` — DynamicSupervisor，支持 `:permanent` restart
3. `SessionWorker` — `is_always_on?` 检查，`maybe_a2a_register` 自动注册
4. `maybe_schedule_heartbeat` — 有 heartbeat_interval 才启动定时器

缺的：
- 所有 agent 的 `auto_start` 都是 `false`
- 所有 agent 的 `always_on` 都是 `false`
- `heartbeat_interval_seconds` 都是 `0`（好，不要改！）

## 实施计划

### Phase 1: DB 更新 — 开启 auto_start + always_on

创建 migration：
```elixir
# 所有 active agent 设置 auto_start=true, always_on=true
# heartbeat_interval_seconds 保持 0（不要 LLM heartbeat）
```

注意：default agent（id=1）特殊处理 — 它是通过 Telegram 消息触发的，
不需要 always_on（已有 session），但 auto_start 可以开。

### Phase 2: AutoStarter 增强

当前问题：AutoStarter 只在启动时跑一次，之后不再检查。

改进：
1. 添加定期检查（每 60 秒）— 确保 auto_start agent 的 session 都在
2. 如果 session 意外消失，重新启动
3. 详细日志：启动了哪些、跳过了哪些（已在运行）、恢复了哪些

```
AutoStarter health check:
  ✓ CTO (agent:CTO:always_on) — running, pid #PID<0.1234.0>
  ✓ Engineering Lead (agent:Engineering Lead:always_on) — running
  ✗ Backend Dev (agent:Backend Dev:always_on) — not found, restarting...
  ✓ Backend Dev restarted successfully
```

### Phase 3: SessionWorker 日志增强

在关键生命周期点添加结构化日志：

```elixir
# init 成功
Logger.info("[Session] Started: #{session_key} | agent=#{agent.name} | always_on=#{agent.always_on} | a2a=#{state.a2a_registered}")

# A2A 注册
Logger.info("[Session] A2A registered: agent=#{agent.name} (id=#{agent.id}) | capabilities=#{inspect(capabilities)}")

# 收到消息
Logger.info("[Session] Message received: #{session_key} | from=#{sender} | length=#{byte_size(content)}")

# 消息处理完成
Logger.info("[Session] Response sent: #{session_key} | duration=#{duration_ms}ms | tokens=#{tokens}")

# terminate
Logger.info("[Session] Terminated: #{session_key} | reason=#{inspect(reason)} | uptime=#{uptime_s}s")
```

### Phase 4: A2A 就绪验证

启动后自动验证 A2A 连通性：
- AutoStarter 完成后，调 `A2ARouter.discover()` 确认所有 agent 都已注册
- 记录详细日志：已注册数量、capabilities 汇总

### Phase 5: 测试

新增测试：
1. `test/clawd_ex/agent/auto_starter_test.exs` 增强：
   - 所有 auto_start agent 在启动后都有 session
   - session crash 后被恢复
   - health check 定时器工作
   
2. `test/clawd_ex/sessions/always_on_test.exs`:
   - always_on session 使用 :permanent restart
   - session crash 后自动重启
   - A2A 注册在重启后恢复

## 文件改动清单

| 文件 | 改动 |
|------|------|
| `priv/repo/migrations/xxx_enable_agent_auto_start.exs` | 新建：batch update auto_start + always_on |
| `lib/clawd_ex/agent/auto_starter.ex` | 增强：定期 health check + 详细日志 |
| `lib/clawd_ex/sessions/session_worker.ex` | 增强：结构化日志 |
| `test/clawd_ex/agent/auto_starter_test.exs` | 增强：health check + recovery 测试 |
| `test/clawd_ex/sessions/always_on_test.exs` | 新建：always_on 完整测试 |

## 不做的事

- **不加 LLM heartbeat** — heartbeat_interval_seconds 保持 0
- **不改 SessionManager** — 已有 :permanent restart 支持
- **不改 A2A Router** — 已有 register/unregister，SessionWorker init 时已自动注册
- **不改 Agent Loop** — 它只在收到消息时才调 AI，空闲不消耗
