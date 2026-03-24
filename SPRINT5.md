# Sprint 5 — 稳定性修复 + E2E 准备

## 目标
1. 测试全绿（修复 1 个 failure + String.to_integer 安全化）
2. 端到端可运行（配置向导 → API key → Telegram 实际对话）
3. Sandbox 安全模式基础

---

## Wave 1: 稳定性修复（并行）

### Task 1: 修复 AdminChannel 测试 (Backend)
**文件:** `test/clawd_ex_web/channels/admin_channel_test.exs:76`
- session clear 返回 `status: :ok` 但测试期望 `status: :error`
- 需要统一行为：清理不存在的 session 应返回 ok 还是 error？
- 建议：清理不存在的 session 返回 ok（幂等设计），修改测试断言

### Task 2: String.to_integer 安全化 (Backend)
**文件清单:**
- `lib/clawd_ex_web/live/chat_live.ex:25,154`
- `lib/clawd_ex_web/live/tasks_live.ex:67,70,91,102,113,124`
- `lib/clawd_ex_web/live/a2a_live.ex:112`

**方案:** 提取 `safe_to_integer/1` helper，处理 nil / "" / 非数字

### Task 3: E2E 启动验证 (Backend)
- 确认 `mix phx.server` 能正常启动
- 确认 Telegram channel 配置路径
- 确认 AI provider key 注入方式
- 验证 WebChat 可访问

---

## Wave 2: Sandbox 安全模式 (串行)

### Task 4: Exec Sandbox 基础 (Backend)
- 命令白名单/黑名单
- 工作区目录限制
- 危险命令拦截 (rm -rf, 网络操作等)

### Task 5: Sandbox 配置 + 测试 (Backend)
- per-agent sandbox 级别 (unrestricted/workspace/strict)
- 配置 UI 集成
- 测试用例

---

## 状态追踪
- [ ] Task 1: AdminChannel 测试修复
- [ ] Task 2: String.to_integer 安全化
- [ ] Task 3: E2E 启动验证
- [ ] Task 4: Exec Sandbox 基础
- [ ] Task 5: Sandbox 配置 + 测试
