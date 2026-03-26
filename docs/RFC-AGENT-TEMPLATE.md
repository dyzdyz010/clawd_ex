# RFC: Agent Template 系统

> 让每个 agent 从模板自动生成自己的 workspace 文件，自带系统知识。

## 问题

当前 ClawdEx 创建新 agent 时：
1. `priv/bootstrap/` 下的模板文件是通用的（给 default agent 用的）
2. 所有 agent 共享同一个 workspace（`~/.clawd/workspace`），bootstrap 文件一样
3. Agent 对自身角色、公司架构、A2A 通信、同事信息一无所知
4. Agent 的 capabilities 为空，导致 A2A Router 无法发现它们
5. 没有 per-agent workspace 隔离

结果：agent 不知道自己是谁、不知道公司有哪些同事、不知道怎么协作。

## 设计方案

### 1. Agent Template（`priv/agent-template/`）

新增一套 agent 专用模板文件，与现有 `priv/bootstrap/` 共存但不冲突：

```
priv/agent-template/
├── AGENTS.md.eex       # Agent 指南（EEx 模板，注入角色信息）
├── SOUL.md.eex         # 角色人格
├── IDENTITY.md.eex     # 身份信息
└── TEAM.md.eex         # 团队成员列表（运行时从 DB 生成）
```

EEx 变量：
- `@agent` — Agent schema 结构体（name, id, capabilities, default_model...）
- `@team` — 其他 agent 列表 `[%{id, name, capabilities, default_model}]`
- `@workspace` — agent 工作目录路径

### 2. Per-Agent Workspace

每个 agent 有自己的 workspace 目录：

```
~/.clawd/workspaces/
├── default/           # agent "default" 的 workspace
│   ├── AGENTS.md
│   ├── SOUL.md
│   ├── IDENTITY.md
│   ├── TEAM.md
│   └── memory/
├── backend-dev/       # agent "Backend Dev" 的 workspace
│   ├── AGENTS.md
│   ├── SOUL.md
│   ├── IDENTITY.md
│   ├── TEAM.md
│   └── memory/
└── ...
```

路径规则：
- 如果 agent 已有 `workspace_path`，使用现有路径
- 否则自动生成：`~/.clawd/workspaces/{slug}/`
- slug = agent name 转 kebab-case（`Backend Dev` → `backend-dev`）

### 3. Agent 创建/启动流程改造

#### 创建时（DB insert 后）：
1. 生成 workspace 目录
2. 从 `priv/agent-template/*.eex` 渲染模板，写入 workspace
3. 设置 `workspace_path` 到 DB

#### 启动时（SessionWorker init）：
1. 检查 workspace 是否存在
2. 如果 `TEAM.md` 不存在或过时，重新生成（从 DB 查所有 agent）
3. A2A 注册（capabilities 非空时）

### 4. Capabilities 自动填充

创建 agent 时，根据角色名自动推荐 capabilities：

```elixir
@role_capabilities %{
  "CTO" => ["architecture", "code-review", "technical-planning"],
  "Engineering Lead" => ["sprint-planning", "code-review", "task-delegation"],
  "Frontend Dev" => ["coding", "frontend", "react", "typescript"],
  "Backend Dev" => ["coding", "backend", "elixir", "database"],
  "DevOps Engineer" => ["coding", "devops", "ci-cd", "deployment"],
  "QA Engineer" => ["coding", "testing", "quality-assurance"],
  "Product Manager" => ["product-planning", "user-stories", "prioritization"],
  "UI/UX Designer" => ["design", "ux-research", "prototyping"],
  "Data Analyst" => ["data-analysis", "metrics", "reporting"],
  "Security Engineer" => ["coding", "security-audit", "compliance"]
}
```

### 5. TEAM.md 内容示例

```markdown
# Team Directory

> 自动生成，请勿手动编辑。最后更新：2026-03-25

## 你的身份
- **名称:** Backend Dev
- **ID:** 5
- **模型:** anthropic/claude-sonnet-4
- **能力:** coding, backend, elixir, database

## 团队成员

| ID | 名称 | 模型 | 能力 | 状态 |
|----|------|------|------|------|
| 1 | default | opus-4 | 个人助理 | 活跃 |
| 2 | CTO | opus-4 | architecture, code-review | 活跃 |
| 3 | Engineering Lead | sonnet-4 | sprint-planning, code-review | 活跃 |
| ...

## A2A 通信

与其他 agent 通信，使用 `a2a` 工具：

- **发现同事:** `a2a(action: "discover")` 
- **发消息:** `a2a(action: "send", targetAgentId: 3, content: "...")`
- **请求协助:** `a2a(action: "request", targetAgentId: 5, content: "...")`
- **委托任务:** `a2a(action: "delegate", targetAgentId: 6, taskTitle: "...")`
```

## 实施计划

### Phase 1: 模板文件和渲染引擎
1. 创建 `priv/agent-template/` 目录和 4 个 `.eex` 模板
2. 新增 `lib/clawd_ex/agents/template.ex` — 模板渲染模块
3. 新增 `lib/clawd_ex/agents/workspace_manager.ex` — per-agent workspace 管理

### Phase 2: Agent 创建流程改造
4. 修改 agent 创建逻辑（DB + workspace init + capabilities）
5. 给现有 11 个 agent 回填 capabilities
6. 给现有 agent 生成 workspace 和模板文件

### Phase 3: 启动和 A2A 集成
7. SessionWorker init 时检查/刷新 TEAM.md
8. 确保 A2A Router 在 agent 启动时正确注册

### Phase 4: 验证
9. 测试：创建新 agent → 自动生成 workspace + 模板
10. 测试：agent 启动 → A2A 发现其他 agent
11. `mix test --no-start` 全绿

## Exec 超时教训

- `mix test --no-start` 需要 ~260 秒，timeout 至少设 400
- `claude --print` 复杂任务需要 5-10 分钟，timeout 至少 600
- `deploy.sh` 包含下载 + 解压 + 重启，timeout 至少 300
- 长任务用 `background: true` + `process poll`，别用同步等

## 不做的事
- 不改现有 `priv/bootstrap/` 文件（那是 default workspace 用的）
- 不改系统提示构建逻辑（Prompt.build 从 workspace 读文件已经 OK）
- 不动 `deploy.sh`
