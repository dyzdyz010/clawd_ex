# Sprint 7 — 多 Agent A2A 增强 + 24 小时 Always-On Agent

## 目标
1. **多 Agent A2A 协作完善** — Agent 间通信可靠、有状态、可调度
2. **24 小时 Always-On Agent** — Heartbeat 驱动的主动式 Agent，不间断运行
3. 从 ROADMAP 中移除 WhatsApp，Sandbox 降级

---

## 分析：当前 A2A 现状

**已有：**
- `A2A.Router` — Agent 注册/发现/消息路由，PubSub 投递，DB 持久化，TTL 过期
- `A2A.Mailbox` — 每 Agent 收件箱，DynamicSupervisor 管理，peek/pop/ack
- `A2A.Message` — Ecto schema，支持 notification/request/response/delegation 类型
- `Tools.A2A` — discover/send/request/respond/delegate 五个 action
- `Agent.Loop` — idle 状态自动检查 mailbox，处理 A2A 消息

**缺失 / 需要增强：**
1. **Agent 自动注册** — Agent 启动时不会自动向 Router 注册 capabilities
2. **跨 Agent 任务编排** — delegate 只创建 Task 发通知，缺少状态跟踪和结果回传
3. **A2A WebSocket/API** — 外部系统无法通过 API 发 A2A 消息
4. **Agent Supervision** — Agent 挂了不会自动重启，没有 health check
5. **A2A 消息优先级** — 所有消息等优先，缺少 urgent/normal/low 分级
6. **Agent 能力声明** — capabilities 是手动字符串，没有结构化 schema

## 分析：24 小时 Agent 现状

**已有：**
- `Cron.Scheduler` — 完整的 cron 执行引擎
- `Cron.Executor` — system_event（注入到 session）+ agent_turn（隔离执行）双模式
- `Prompt` 系统 — HEARTBEAT.md 注入
- `Agent.Loop` — 有 timeout 机制

**缺失：**
1. **Heartbeat 循环** — 没有内建 heartbeat 定时器，依赖外部 cron
2. **Always-On SessionWorker** — SessionWorker 超时后会终止，没有 keep-alive
3. **Agent 自启动** — 系统启动时不会自动启动配置的 Agent
4. **健康监控** — 没有 Agent 级别的 health check 和自动恢复
5. **Session 持久化恢复** — 重启后 session 状态丢失

---

## Wave 1: Agent 自启动 + 自动注册（后端 #1）

### Task 1.1: Agent Auto-Start
**新文件:** `lib/clawd_ex/agent/supervisor.ex`
- 系统启动时读取 DB 中所有 `auto_start: true` 的 Agent
- 为每个自启动 Agent 创建 persistent session
- SessionWorker 使用 `:permanent` restart 策略

### Task 1.2: Agent Auto-Register to A2A
- SessionWorker 启动时自动向 A2A.Router 注册
- capabilities 从 Agent schema 的新字段读取
- SessionWorker 终止时自动 unregister

### Task 1.3: Agent Schema 扩展
**修改:** `lib/clawd_ex/agents/agent.ex` (Ecto schema)
- 新字段: `auto_start` (boolean, default false)
- 新字段: `capabilities` (array of strings)
- 新字段: `heartbeat_interval_seconds` (integer, default 0 = disabled)
- 新字段: `always_on` (boolean, default false)
- Migration

---

## Wave 2: Always-On Agent + Heartbeat（后端 #2）

### Task 2.1: Heartbeat Timer
**修改:** `lib/clawd_ex/sessions/session_worker.ex`
- Agent 配置了 `heartbeat_interval_seconds > 0` 时，启动内建定时器
- 定时注入 heartbeat 消息到 Agent Loop
- Heartbeat 消息格式：读 agent workspace 的 HEARTBEAT.md 内容
- Agent 回复 "HEARTBEAT_OK" 时不投递到渠道（静默处理）
- Agent 回复其他内容时正常投递（主动通知用户）

### Task 2.2: Keep-Alive SessionWorker
- `always_on: true` 的 Agent，SessionWorker 永不超时退出
- Agent Loop run 完成后回到 idle，等待下一条消息或 heartbeat
- crash 后 Supervisor 自动重启
- 重启后从 DB 恢复最近 N 条消息作为上下文

### Task 2.3: Session State Persistence
- SessionWorker 定期将关键状态写入 DB（不是每条消息，而是 checkpoint）
- 重启后从最近 checkpoint 恢复
- 包括 message count, last active time, model override 等

---

## Wave 3: A2A 增强（后端 #3）

### Task 3.1: 消息优先级
**修改:** `A2A.Message` schema + `A2A.Mailbox`
- 新字段: `priority` (integer, 1=urgent, 5=normal, 10=low)
- Mailbox 按优先级排序（priority queue 替代 FIFO queue）
- Agent Loop 优先处理 urgent 消息

### Task 3.2: 任务编排增强
**修改:** `Tools.A2A` delegate action
- delegate 后跟踪 Task 状态
- 目标 Agent 完成任务后自动回传结果给发起者
- 新 action: `check_delegation` — 查看委托任务状态
- 新 action: `broadcast` — 向所有注册 Agent 广播消息

### Task 3.3: A2A REST API
**新文件:** `lib/clawd_ex_web/controllers/api/a2a_controller.ex`
- POST /api/a2a/messages — 发送消息
- GET /api/a2a/agents — 发现可用 Agent
- GET /api/a2a/messages/:agent_id — 获取 Agent 收件箱
- 需要 API key 认证

---

## Wave 4: 管理界面 + 测试（前端 + QA）

### Task 4.1: Agent 管理 UI 增强
**修改:** Agent 创建/编辑表单
- 新增 auto_start 开关
- 新增 capabilities 输入（tag 风格）
- 新增 heartbeat_interval 输入
- 新增 always_on 开关
- Agent 列表显示在线状态（绿点/灰点）

### Task 4.2: A2A 监控面板
**修改:** `a2a_live.ex`
- 显示注册的 Agent 列表及在线状态
- 消息流实时展示
- 消息统计（发送/接收/超时/过期）

### Task 4.3: 完整测试覆盖
- Agent auto-start 测试
- Heartbeat timer 测试
- Always-on crash recovery 测试
- A2A priority queue 测试
- A2A delegation tracking 测试
- REST API 测试

---

## 任务分配

| 任务 | 负责 | 预估 |
|------|------|------|
| Wave 1: Agent 自启动 + 注册 | Backend #1 | ~15min |
| Wave 2: Always-On + Heartbeat | Backend #2 | ~15min |
| Wave 3: A2A 增强 | Backend #3 | ~15min |
| Wave 4.1-4.2: UI 增强 | Frontend | ~10min |
| Wave 4.3: 测试 | QA | ~10min |
| 全量代码审查 | Reviewer | ~10min |

## 完成标准
- `mix test --no-start` → 0 failures（新增测试也全绿）
- Agent 配置 auto_start=true + always_on=true 后系统启动自动运行
- Heartbeat 按配置间隔触发
- A2A 消息优先级正确排序
- A2A REST API 可用
- 所有改动已 commit
