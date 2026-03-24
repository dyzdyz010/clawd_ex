# Sprint 6 — 测试全绿 + 稳定性 + E2E

## 目标
1. **1704 tests, 0 failures** — 从 933 failures 修到 0
2. **E2E 可运行** — `mix phx.server` 启动无报错
3. **Sprint 5 遗留任务清理**

---

## 错误分析（933 failures 分类）

| 错误类型 | 数量 | 根因 |
|---------|------|------|
| MatchError | 774 | 函数返回值变了但测试/调用方没更新 |
| no process (GenServer) | 102 | 测试环境缺少进程启动 |
| unknown registry: Req.Finch | 31 | HTTP 客户端未启动 |
| Skills.Registry not started | 20 | 技能注册表未启动 |
| MCP.ServerManager not started | 10 | MCP 管理器未启动 |
| NodeBridge not started | 10 | 插件 NodeBridge 未启动 |
| unknown registry: PubSub | 9 | PubSub 未启动 |
| OAuth not started | 6 | OAuth GenServer 未启动 |
| A2AMailboxRegistry | 3 | A2A 注册表未启动 |
| SessionRegistry | 2 | Session 注册表未启动 |
| 其他 | ~少量 | ApiKey/Browser 等 |

## 修复策略

### Wave 1: 测试基础设施（最高优先级）
**目标：修复 ~150+ failures（no process / unknown registry 类）**

1. **test_helper.exs 增强** — 确保测试需要的 GenServer/Registry 在 setup 中启动或 mock
2. **共享 test fixtures** — 创建 `test/support/` 下的 setup helpers
3. **Req.Finch 启动** — 在 test config 中确保 HTTP 客户端可用
4. **PubSub 测试启动** — 确保 Phoenix.PubSub 在测试中注册

### Wave 2: MatchError 批量修复（主攻方向）
**目标：修复 774 个 MatchError failures**

这些最可能来自最近的重构（Gateway, Plugin System V2, Provider 抽象层），函数签名/返回值变了但测试或调用方未同步。

策略：
1. 按模块分组找出哪些模块最多 failures
2. 从 core 模块向外修（先修被依赖的，再修依赖方）
3. 确保 API 契约统一

### Wave 3: Sprint 5 遗留
1. AdminChannel 测试修复
2. String.to_integer 安全化（SafeParse helper）
3. E2E 启动验证

---

## 任务分配

| 任务 | 负责 | Topic |
|------|------|-------|
| Wave 1: 测试基础设施修复 | Backend #1 | ⚙️ 后端 |
| Wave 2: MatchError 批量修复 | Backend #2 | ⚙️ 后端 |
| Wave 3: Sprint 5 遗留 + SafeParse | Backend #3 | ⚙️ 后端 |
| 代码审查 | Reviewer | 🔍 审查 |
| 最终测试验证 | QA | 🧪 测试 |

## 完成标准
- `mix test --no-start` → 0 failures
- `mix phx.server` → 启动无报错
- 所有改动已 commit
