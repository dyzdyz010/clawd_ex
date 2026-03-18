# Sprint 4 — 稳定性 + Skills 系统

## Wave 1: 稳定性扫雷

### Task 1: spawn/1 → 监控化 (Backend)
裸 `spawn/1` 进程崩溃无人知道，需要改为有监控的方式。

**文件清单:**
- `lib/clawd_ex/tools/exec.ex` (2处): port monitor 进程
  - 需要 `Task.Supervisor.start_child` 而非裸 spawn
  - 因为这些进程需要在调用者退出后继续存活
- `lib/clawd_ex/tools/gateway.ex` (1处): restart 进程
  - fire-and-forget，用 `Task.Supervisor.start_child`
- `lib/clawd_ex/channels/telegram.ex` (1处): typing indicator
  - 短生命周期+有 stop 机制，风险低，但改成 Task 更规范

**方案:**
1. 在 Application supervisor 下加一个 `Task.Supervisor` (名: `ClawdEx.TaskSupervisor`)
2. 所有裸 spawn 改为 `Task.Supervisor.start_child(ClawdEx.TaskSupervisor, fn -> ... end)`

### Task 2: max_tool_iterations 调优 (Backend)
- 当前值 50 可能太低（复杂任务需要更多迭代）
- OpenClaw 默认应该是几百次
- 改为 200，并加配置项支持

### Task 3: String.to_integer 安全化 (Backend)
- `webhooks_live.ex` 有 `String.to_integer(id)` 直接调用
- 如果传入非数字会崩溃
- 改为安全解析

## Wave 2: Skills 系统

### Task 4: Skills 基础架构
- Skill schema (name, description, location, enabled)
- Skill loader (从文件系统读取 SKILL.md)
- Skill registry (GenServer 管理加载的 skills)
- Skill 注入到 agent prompt

### Task 5: Skills LiveView 管理页面
- Skills 列表页
- Skill 详情/启用禁用

---

## 状态追踪
- [ ] Task 1: spawn 监控化
- [ ] Task 2: max_tool_iterations
- [ ] Task 3: String.to_integer
- [ ] Task 4: Skills 基础架构
- [ ] Task 5: Skills LiveView
