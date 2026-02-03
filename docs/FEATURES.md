# ClawdEx vs OpenClaw 功能对比

> 完整功能清单，对照 OpenClaw 项目

## 图例
- ✅ 已完成
- 🚧 部分完成
- ⬜ 未开始

---

## 1. CLI 命令行工具

| 功能 | OpenClaw | ClawdEx | 说明 |
|------|----------|---------|------|
| `openclaw` 主命令 | ✅ | ⬜ | Mix task 或 escript |
| `openclaw status` | ✅ | ⬜ | 系统状态概览 |
| `openclaw health` | ✅ | ⬜ | 健康检查 |
| `openclaw doctor` | ✅ | ⬜ | 诊断问题 |
| `openclaw configure` | ✅ | ⬜ | 交互式配置 |
| `openclaw onboard` | ✅ | ⬜ | 引导设置向导 |
| `openclaw gateway start/stop/restart` | ✅ | ⬜ | Gateway 管理 |
| `openclaw gateway status` | ✅ | ⬜ | Gateway 状态 |
| `openclaw channels status/add/remove` | ✅ | ⬜ | 渠道管理 |
| `openclaw cron list/add/remove/run` | ✅ | ⬜ | 定时任务 CLI |
| `openclaw sessions list/history` | ✅ | ⬜ | 会话 CLI |
| `openclaw agents list/add/delete` | ✅ | ⬜ | Agent CLI |
| `openclaw models list/set` | ✅ | ⬜ | 模型管理 |
| `openclaw memory search` | ✅ | ⬜ | 记忆搜索 CLI |
| `openclaw browser` | ✅ | ⬜ | 浏览器 CLI |
| `openclaw nodes` | ✅ | ⬜ | 节点 CLI |
| `openclaw logs` | ✅ | ⬜ | 日志查看 |
| `openclaw plugins` | ✅ | ⬜ | 插件管理 |
| `openclaw skills` | ✅ | ⬜ | 技能管理 |
| `openclaw sandbox` | ✅ | ⬜ | 沙箱管理 |
| `openclaw update` | ✅ | ⬜ | 自更新 |
| `openclaw message send` | ✅ | ⬜ | 发送消息 |
| `openclaw hooks` | ✅ | ⬜ | Webhook 管理 |
| 命令自动补全 | ✅ | ⬜ | bash/zsh/fish |

## 2. TUI 终端界面

| 功能 | OpenClaw | ClawdEx | 说明 |
|------|----------|---------|------|
| `openclaw tui` | ✅ | ⬜ | 终端聊天 UI |
| 流式响应显示 | ✅ | ⬜ | |
| 工具调用显示 | ✅ | ⬜ | |
| 命令模式 | ✅ | ⬜ | /command |
| 历史记录 | ✅ | ⬜ | 上下箭头 |
| 主题切换 | ✅ | ⬜ | |
| 状态栏 | ✅ | ⬜ | |

## 3. Web 管理界面

| 功能 | OpenClaw | ClawdEx | 说明 |
|------|----------|---------|------|
| Dashboard | ✅ | ✅ | 系统概览 |
| Chat 界面 | ✅ | ✅ | 实时聊天 |
| Sessions 列表 | ✅ | ✅ | 会话管理 |
| Session 详情 | ✅ | ✅ | 消息历史 |
| Agents 管理 | ✅ | ✅ | CRUD |
| **配置编辑器** | ✅ | ⬜ | JSON/YAML 编辑 |
| **Gateway 状态面板** | ✅ | ⬜ | 状态指示灯 |
| **健康检查页** | ✅ | ⬜ | 服务状态 |
| **日志查看器** | ✅ | ⬜ | 实时日志 |
| **Cron 管理界面** | ✅ | ⬜ | 定时任务 UI |
| **渠道配置** | ✅ | ⬜ | 渠道账户管理 |
| **模型配置** | ✅ | ⬜ | 模型选择 |
| **Nodes 管理** | ✅ | ⬜ | 节点配对 UI |
| **Skills 管理** | ✅ | ⬜ | 技能 UI |
| **Plugins 管理** | ✅ | ⬜ | 插件 UI |
| **账户管理** | ✅ | ⬜ | WhatsApp/Telegram 登录 |
| 侧边栏导航 | ✅ | ✅ | |
| 深色主题 | ✅ | ✅ | |

## 4. Gateway 服务

| 功能 | OpenClaw | ClawdEx | 说明 |
|------|----------|---------|------|
| HTTP/WebSocket 服务 | ✅ | 🚧 | Phoenix 端点 |
| 启动/停止/重启 | ✅ | 🚧 | 通过 gateway 工具 |
| 配置热重载 | ✅ | ⬜ | 不重启更新配置 |
| 健康检查端点 | ✅ | ⬜ | /health |
| 认证 (token/password) | ✅ | ⬜ | |
| 多会话管理 | ✅ | ✅ | |
| 广播消息 | ✅ | ⬜ | |
| Node 事件订阅 | ✅ | ⬜ | |
| 插件加载 | ✅ | ⬜ | |
| 守护进程模式 | ✅ | ⬜ | systemd/launchd |
| 自动重启 | ✅ | ⬜ | |

## 5. 消息渠道

| 渠道 | OpenClaw | ClawdEx | 说明 |
|------|----------|---------|------|
| Telegram | ✅ | ✅ | Telegex |
| Discord | ✅ | ✅ | Nostrum |
| WebChat | ✅ | ✅ | LiveView |
| **WhatsApp** | ✅ | ⬜ | baileys/web |
| **Signal** | ✅ | ⬜ | signal-cli |
| **Slack** | ✅ | ⬜ | Socket Mode |
| **iMessage** | ✅ | ⬜ | macOS only |
| **Google Chat** | ✅ | ⬜ | |
| **Line** | ✅ | ⬜ | |
| 渠道账户管理 | ✅ | ⬜ | 登录/登出 |
| QR 码登录 | ✅ | ⬜ | WhatsApp |
| 多账户支持 | ✅ | ⬜ | |

## 6. AI 提供商

| 提供商 | OpenClaw | ClawdEx | 说明 |
|--------|----------|---------|------|
| Anthropic Claude | ✅ | ✅ | |
| Anthropic OAuth | ✅ | ✅ | Token 刷新 |
| OpenAI GPT | ✅ | ✅ | |
| Google Gemini | ✅ | ✅ | |
| OpenRouter | ✅ | ✅ | |
| **GitHub Copilot** | ✅ | ⬜ | |
| **Qwen** | ✅ | ⬜ | |
| **MiniMax** | ✅ | ⬜ | |
| **Ollama** | ✅ | ⬜ | 本地模型 |
| **Groq** | ✅ | ⬜ | |
| 模型别名 | ✅ | ✅ | |
| 流式响应 | ✅ | ✅ | |
| 重试机制 | ✅ | ✅ | |

## 7. 工具系统

| 工具 | OpenClaw | ClawdEx | 说明 |
|------|----------|---------|------|
| read | ✅ | ✅ | |
| write | ✅ | ✅ | |
| edit | ✅ | ✅ | |
| exec | ✅ | ✅ | |
| process | ✅ | ✅ | |
| memory_search | ✅ | ✅ | |
| memory_get | ✅ | ✅ | |
| web_search | ✅ | ✅ | |
| web_fetch | ✅ | ✅ | |
| browser | ✅ | ✅ | |
| sessions_list | ✅ | ✅ | |
| sessions_history | ✅ | ✅ | |
| sessions_send | ✅ | ✅ | |
| sessions_spawn | ✅ | ✅ | |
| agents_list | ✅ | ✅ | |
| session_status | ✅ | ✅ | |
| cron | ✅ | ✅ | |
| gateway | ✅ | 🚧 | 部分功能 |
| message | ✅ | ✅ | |
| nodes | ✅ | ✅ | |
| canvas | ✅ | ✅ | |
| tts | ✅ | ✅ | |
| image | ✅ | ✅ | |
| compact | ✅ | ✅ | |
| **apply_patch** | ✅ | ⬜ | 多文件补丁 |

## 8. Sessions/Subagent

| 功能 | OpenClaw | ClawdEx | 说明 |
|------|----------|---------|------|
| 会话创建 | ✅ | ✅ | |
| 会话列表 | ✅ | ✅ | |
| 会话历史 | ✅ | ✅ | |
| 会话压缩 | ✅ | ✅ | |
| 子代理生成 | ✅ | ✅ | sessions_spawn |
| 跨会话消息 | ✅ | ✅ | sessions_send |
| **子代理结果回调** | ✅ | 🚧 | announce/deliver |
| **子代理超时处理** | ✅ | 🚧 | |
| **子代理 cleanup** | ✅ | ⬜ | delete/keep |
| **会话标签** | ✅ | ⬜ | label |
| **会话模型覆盖** | ✅ | 🚧 | |

## 9. Cron 定时任务

| 功能 | OpenClaw | ClawdEx | 说明 |
|------|----------|---------|------|
| 任务创建 | ✅ | ✅ | |
| 任务列表 | ✅ | ✅ | |
| 任务删除 | ✅ | ✅ | |
| 手动触发 | ✅ | ✅ | |
| 执行历史 | ✅ | ✅ | |
| **Web UI 管理** | ✅ | ⬜ | |
| **CLI 管理** | ✅ | ⬜ | |
| Cron 表达式 | ✅ | ✅ | |
| 一次性任务 (at) | ✅ | ✅ | |
| 间隔任务 (every) | ✅ | ✅ | |

## 10. 记忆系统

| 功能 | OpenClaw | ClawdEx | 说明 |
|------|----------|---------|------|
| 向量搜索 | ✅ | ✅ | pgvector |
| BM25 搜索 | ✅ | ✅ | |
| 混合搜索 | ✅ | ✅ | |
| 中文分词 | ✅ | ✅ | |
| 文档分块 | ✅ | ✅ | |
| **CLI 搜索** | ✅ | ⬜ | |
| **索引管理** | ✅ | ⬜ | |

## 11. 浏览器自动化

| 功能 | OpenClaw | ClawdEx | 说明 |
|------|----------|---------|------|
| CDP 控制 | ✅ | ✅ | |
| 页面导航 | ✅ | ✅ | |
| 截图 | ✅ | ✅ | |
| 快照 (aria/ai) | ✅ | ✅ | |
| 交互动作 | ✅ | ✅ | |
| JS 执行 | ✅ | ✅ | |
| **多 Profile 支持** | ✅ | ⬜ | chrome/openclaw |
| **Chrome 扩展** | ✅ | ⬜ | Browser Relay |
| **Cookie/Storage** | ✅ | ⬜ | |

## 12. 节点系统

| 功能 | OpenClaw | ClawdEx | 说明 |
|------|----------|---------|------|
| 节点注册 | ✅ | ✅ | |
| 节点状态 | ✅ | ✅ | |
| 远程通知 | ✅ | ✅ | |
| 远程执行 | ✅ | ✅ | |
| 摄像头控制 | ✅ | ✅ | |
| 屏幕录制 | ✅ | ✅ | |
| 位置获取 | ✅ | ✅ | |
| **配对流程 UI** | ✅ | ⬜ | |
| **Canvas 托管** | ✅ | ⬜ | |

## 13. 配置系统

| 功能 | OpenClaw | ClawdEx | 说明 |
|------|----------|---------|------|
| 配置文件 | ✅ | ✅ | config/*.exs |
| 环境变量 | ✅ | ✅ | |
| **运行时修改** | ✅ | ⬜ | 不重启 |
| **Web 编辑器** | ✅ | ⬜ | |
| **CLI 编辑** | ✅ | ⬜ | |
| **配置验证** | ✅ | ⬜ | |
| **配置向导** | ✅ | ⬜ | |
| **$include 支持** | ✅ | ⬜ | |

## 14. 安全系统

| 功能 | OpenClaw | ClawdEx | 说明 |
|------|----------|---------|------|
| API Key 管理 | ✅ | ✅ | |
| OAuth 认证 | ✅ | ✅ | |
| **Gateway 认证** | ✅ | ⬜ | token/password |
| **DM 配对** | ✅ | ⬜ | |
| **群组白名单** | ✅ | ⬜ | allowFrom |
| **工具权限** | ✅ | ⬜ | allow/deny |
| **Sandbox 模式** | ✅ | ⬜ | Docker 隔离 |
| **Exec 审批** | ✅ | ⬜ | |

## 15. 日志系统

| 功能 | OpenClaw | ClawdEx | 说明 |
|------|----------|---------|------|
| 日志记录 | ✅ | ✅ | Logger |
| **日志文件** | ✅ | ⬜ | 持久化 |
| **日志查看 CLI** | ✅ | ⬜ | openclaw logs |
| **日志 Web UI** | ✅ | ⬜ | 实时查看 |
| **日志级别控制** | ✅ | 🚧 | |

## 16. 插件系统

| 功能 | OpenClaw | ClawdEx | 说明 |
|------|----------|---------|------|
| 插件加载 | ✅ | ⬜ | |
| 插件注册表 | ✅ | ⬜ | clawhub.com |
| 渠道插件 | ✅ | ⬜ | |
| 工具插件 | ✅ | ⬜ | |
| Provider 插件 | ✅ | ⬜ | |

## 17. Skills 技能系统

| 功能 | OpenClaw | ClawdEx | 说明 |
|------|----------|---------|------|
| 技能加载 | ✅ | ⬜ | SKILL.md |
| 技能列表 | ✅ | ⬜ | |
| 技能 CLI | ✅ | ⬜ | |
| 技能 UI | ✅ | ⬜ | |

## 18. Hooks/Webhooks

| 功能 | OpenClaw | ClawdEx | 说明 |
|------|----------|---------|------|
| Webhook 接收 | ✅ | ⬜ | |
| Webhook 配置 | ✅ | ⬜ | |
| Git hooks | ✅ | ⬜ | |
| 自定义触发器 | ✅ | ⬜ | |

---

## 统计总结

| 类别 | 完成 | 部分 | 未开始 | 总计 |
|------|------|------|--------|------|
| CLI 命令行 | 0 | 0 | 24 | 24 |
| TUI 终端界面 | 0 | 0 | 7 | 7 |
| Web 管理界面 | 5 | 0 | 12 | 17 |
| Gateway 服务 | 1 | 2 | 8 | 11 |
| 消息渠道 | 3 | 0 | 8 | 11 |
| AI 提供商 | 5 | 0 | 5 | 10 |
| 工具系统 | 22 | 1 | 1 | 24 |
| Sessions/Subagent | 6 | 2 | 2 | 10 |
| Cron 定时任务 | 6 | 0 | 2 | 8 |
| 记忆系统 | 5 | 0 | 2 | 7 |
| 浏览器自动化 | 6 | 0 | 3 | 9 |
| 节点系统 | 7 | 0 | 2 | 9 |
| 配置系统 | 2 | 0 | 6 | 8 |
| 安全系统 | 2 | 0 | 6 | 8 |
| 日志系统 | 1 | 1 | 3 | 5 |
| 插件系统 | 0 | 0 | 5 | 5 |
| Skills 系统 | 0 | 0 | 4 | 4 |
| Hooks/Webhooks | 0 | 0 | 4 | 4 |
| **总计** | **71** | **6** | **104** | **181** |

**当前完成度: 约 39% (核心工具已完成，但周边功能大量缺失)**

---

## 优先级建议

### P0 - 核心体验 (建议优先)
1. ⬜ CLI 基础命令 (status/health/configure)
2. ⬜ Gateway 状态面板 + 健康检查
3. ⬜ 日志查看器 (Web UI)
4. ⬜ Cron 管理界面
5. ⬜ 配置编辑器 (Web UI)

### P1 - 重要功能
1. ⬜ TUI 终端界面
2. ⬜ 子代理完整功能 (cleanup/label)
3. ⬜ WhatsApp 渠道
4. ⬜ Signal 渠道
5. ⬜ Sandbox 安全模式

### P2 - 增强功能
1. ⬜ 更多 AI 提供商
2. ⬜ 插件系统
3. ⬜ Skills 系统
4. ⬜ Hooks/Webhooks
5. ⬜ 浏览器多 Profile

### P3 - 可选功能
1. ⬜ Slack/Line/iMessage 渠道
2. ⬜ Chrome 扩展
3. ⬜ 配置向导
4. ⬜ apply_patch 工具
