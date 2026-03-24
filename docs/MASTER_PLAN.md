# ClawdEx 开发总计划

> 按优先级排序的完整开发计划，涵盖所有未完成功能。
> 每个 Sprint 约 1-2 个工作日，3-5 个并行子代理。
> 最后更新: 2026-03-24

---

## 当前状态

- **代码库**: 1749 tests, 0 failures
- **完成度**: ~59% (117/209 功能完成，6 项部分完成，86 项未开始)
- **最新 commit**: `3e7a91f` Sprint 7 — Multi-Agent A2A + Always-On Agent

---

## 优先级分层原则

| 优先级 | 标准 | 目标 |
|--------|------|------|
| **P0** | 没有就不能用 | MVP 可用 |
| **P1** | 核心体验 | 日常好用 |
| **P2** | 竞争力功能 | 功能完整 |
| **P3** | 锦上添花 | 差异化 |

---

## Sprint 8 — Sessions & Subagent 补完 (P0)

> 把 🚧 项全部做完，确保子代理系统生产可用

| # | 任务 | 当前 | 负责 | 说明 |
|---|------|------|------|------|
| 8.1 | 子代理结果回调完善 | 🚧 | Backend | announce 投递到父会话渠道（Telegram/Discord），支持 streamTo |
| 8.2 | 子代理超时处理 | 🚧 | Backend | timeout 到期自动 kill + 通知父会话 |
| 8.3 | 会话模型覆盖 | 🚧 | Backend | session_status 工具设置 per-session model，Agent Loop 读取 |
| 8.4 | Gateway 工具补完 | 🚧 | Backend | restart/config/status action 完整实现 |
| 8.5 | 日志级别运行时控制 | 🚧 | Backend | Logger 级别动态切换 |
| 8.6 | 测试 + 验证 | — | QA | 上述 5 项的测试覆盖 |

**完成标准**: 所有 🚧 变 ✅，子代理全链路闭环可用

---

## Sprint 9 — 安全系统基础 (P0)

> 没有安全就不能上线

| # | 任务 | 负责 | 说明 |
|---|------|------|------|
| 9.1 | Gateway 认证 | Backend | token/password 认证，WebSocket + REST 统一 |
| 9.2 | DM 配对 | Backend | Telegram/Discord 私聊自动绑定 agent |
| 9.3 | 群组白名单 | Backend | allowFrom 配置，忽略非白名单群消息 |
| 9.4 | 工具权限控制 | Backend | per-agent allow/deny 工具列表 |
| 9.5 | Exec 审批 | Backend | 危险命令拦截 + 用户确认流程 |
| 9.6 | Sandbox 基础 | Backend | 工作区目录限制，命令黑名单 |

**完成标准**: Agent 不能执行未授权操作，Gateway 需认证访问

---

## Sprint 10 — Web 管理界面补完 (P1)

> 让 Web 管理面板功能完整

| # | 任务 | 负责 | 说明 |
|---|------|------|------|
| 10.1 | Gateway 状态面板 | Frontend | 在线/离线指示灯，连接数，uptime |
| 10.2 | 渠道配置 UI | Frontend | Telegram token、Discord token 配置表单 |
| 10.3 | 模型配置 UI | Frontend | 模型列表、per-agent 模型选择 |
| 10.4 | Nodes 管理 UI | Frontend | 节点列表、配对审批、状态监控 |
| 10.5 | Agent 管理增强 | Frontend | auto_start/always_on/capabilities/heartbeat 编辑 |
| 10.6 | 账户管理 UI | Frontend | Telegram/Discord 账户状态、重连 |

**完成标准**: 所有配置可通过 Web UI 完成，不需要手动编辑配置文件

---

## Sprint 11 — CLI 命令补全 (P1)

> CLI 是开发者的主要交互方式

| # | 任务 | 负责 | 说明 |
|---|------|------|------|
| 11.1 | 主命令框架 | Backend | `clawd_ex` 或 `cex` 主入口，子命令路由 |
| 11.2 | gateway 子命令 | Backend | start/stop/restart/status |
| 11.3 | channels 子命令 | Backend | status/add/remove |
| 11.4 | models 子命令 | Backend | list/set/info |
| 11.5 | memory 子命令 | Backend | search/index |
| 11.6 | browser 子命令 | Backend | start/stop/screenshot |
| 11.7 | nodes 子命令 | Backend | list/approve/reject |
| 11.8 | logs 子命令 | Backend | tail/filter/level |
| 11.9 | plugins 子命令 | Backend | list/install/uninstall |
| 11.10 | skills 子命令 | Backend | list/info/refresh |
| 11.11 | message 子命令 | Backend | send (指定渠道+目标) |
| 11.12 | hooks 子命令 | Backend | list/add/remove/test |
| 11.13 | doctor 子命令 | Backend | 全面诊断（DB/AI/Channel/Memory） |
| 11.14 | onboard 子命令 | Backend | 引导式首次配置向导 |
| 11.15 | update 子命令 | Backend | 自更新（git pull + mix deps.get + migrate） |
| 11.16 | sandbox 子命令 | Backend | 状态查看/配置 |
| 11.17 | 命令自动补全 | Backend | bash/zsh/fish 补全脚本生成 |

**完成标准**: 所有 OpenClaw CLI 对等命令可用

---

## Sprint 12 — AI 提供商扩展 (P1)

> 补全剩余 AI 提供商

| # | 任务 | 负责 | 说明 |
|---|------|------|------|
| 12.1 | Qwen Provider | Backend | 通义千问 API，走 OpenAICompat |
| 12.2 | GitHub Copilot Provider | Backend | Copilot Chat API |
| 12.3 | MiniMax Provider | Backend | MiniMax API |

**完成标准**: 所有已列提供商可配置可用

---

## Sprint 13 — Signal 渠道 (P1)

> 新增消息渠道

| # | 任务 | 负责 | 说明 |
|---|------|------|------|
| 13.1 | Signal Channel | Backend | signal-cli 集成，收发消息 |
| 13.2 | 渠道账户管理 | Backend | 登录/登出/多账户 |
| 13.3 | Slack Channel | Backend | Socket Mode API |
| 13.4 | 测试 | QA | 各渠道消息收发测试 |

**完成标准**: Signal + Slack 可收发消息

---

## Sprint 14 — Gateway 服务完善 (P1)

> 让 Gateway 成为可靠的生产服务

| # | 任务 | 负责 | 说明 |
|---|------|------|------|
| 14.1 | 配置热重载 | Backend | 不重启更新渠道/模型/Agent 配置 |
| 14.2 | 健康检查端点 | Backend | GET /health JSON 返回各子系统状态 |
| 14.3 | 广播消息 | Backend | 向所有活跃 session 广播 |
| 14.4 | Node 事件订阅 | Backend | WebSocket 推送节点事件 |
| 14.5 | 插件加载 | Backend | Gateway 启动时加载 plugin |
| 14.6 | 守护进程模式 | Backend/DevOps | systemd service 文件 + launchd plist |
| 14.7 | 自动重启 | Backend | crash 后自动恢复，supervisor strategy |

**完成标准**: Gateway 可作为后台守护进程稳定运行

---

## Sprint 15 — TUI 终端界面 (P2)

> 终端交互体验

| # | 任务 | 负责 | 说明 |
|---|------|------|------|
| 15.1 | TUI 框架 | Backend | Ratatouille 或 Owl 选型 |
| 15.2 | 聊天界面 | Frontend | 消息展示 + 输入框 |
| 15.3 | 流式响应 | Backend | SSE/stream 实时显示 |
| 15.4 | 工具调用显示 | Frontend | spinner + 折叠展示 |
| 15.5 | 命令模式 | Backend | /command 解析 |
| 15.6 | 历史记录 | Backend | 上下箭头 + 搜索 |
| 15.7 | 状态栏 | Frontend | 模型/token/时间 |

**完成标准**: `cex tui` 可启动终端聊天

---

## Sprint 16 — 配置系统完善 (P2)

| # | 任务 | 负责 | 说明 |
|---|------|------|------|
| 16.1 | 运行时配置修改 | Backend | 不重启修改配置 |
| 16.2 | CLI 配置编辑 | Backend | `cex config set/get/list` |
| 16.3 | 配置验证 | Backend | schema 校验 + 错误提示 |
| 16.4 | $include 支持 | Backend | 配置文件引用其他文件 |

**完成标准**: 配置可通过 CLI/Web/运行时三种方式修改

---

## Sprint 17 — 浏览器增强 (P2)

| # | 任务 | 负责 | 说明 |
|---|------|------|------|
| 17.1 | 多 Profile 支持 | Backend | chrome/isolated 切换 |
| 17.2 | Chrome 扩展 | Frontend | Browser Relay 扩展 |
| 17.3 | Cookie/Storage | Backend | 持久化 cookie 和 localStorage |

**完成标准**: 浏览器可切换 Profile，支持登录态保持

---

## Sprint 18 — 插件系统 (P2)

| # | 任务 | 负责 | 说明 |
|---|------|------|------|
| 18.1 | 插件加载器 | Backend | 动态加载 .exs/.js 插件 |
| 18.2 | 插件注册表 | Backend | 本地 + 远程插件目录 |
| 18.3 | 渠道插件 | Backend | 渠道可作为插件扩展 |
| 18.4 | 工具插件 | Backend | 自定义工具注册 |
| 18.5 | Provider 插件 | Backend | 自定义 AI 提供商 |

**完成标准**: 第三方可开发和安装插件

---

## Sprint 19 — Skills 系统 (P2)

| # | 任务 | 负责 | 说明 |
|---|------|------|------|
| 19.1 | SKILL.md 加载 | Backend | 读取 + 注入 system prompt |
| 19.2 | 技能列表 API | Backend | 列出已加载技能 |
| 19.3 | 技能 CLI | Backend | list/info/refresh |
| 19.4 | 技能 Web UI | Frontend | 列表 + 启用/禁用 |

**完成标准**: Skills 可自动发现、加载、注入到 Agent

---

## Sprint 20 — Hooks/Webhooks (P2)

| # | 任务 | 负责 | 说明 |
|---|------|------|------|
| 20.1 | Webhook 接收端点 | Backend | POST /api/webhooks/:name |
| 20.2 | Webhook 配置 | Backend | URL + secret + 事件过滤 |
| 20.3 | Git hooks | Backend | pre-push/post-commit 触发 Agent |
| 20.4 | 自定义触发器 | Backend | 事件名 → Agent 动作映射 |

**完成标准**: 外部系统可通过 Webhook 触发 Agent 行为

---

## Sprint 21 — 日志 & 记忆补全 (P2)

| # | 任务 | 负责 | 说明 |
|---|------|------|------|
| 21.1 | 日志文件持久化 | Backend | Logger file backend |
| 21.2 | 日志查看 CLI | Backend | `cex logs --tail --level error` |
| 21.3 | 记忆搜索 CLI | Backend | `cex memory search "xxx"` |
| 21.4 | 记忆索引管理 | Backend | 重建索引/清理/统计 |

**完成标准**: 日志可持久化查看，记忆可通过 CLI 搜索管理

---

## Sprint 22 — 节点系统补完 (P2)

| # | 任务 | 负责 | 说明 |
|---|------|------|------|
| 22.1 | 节点配对 UI | Frontend | Web 上审批节点配对请求 |
| 22.2 | Canvas 托管 | Backend | 节点侧 Canvas 渲染代理 |

---

## Sprint 23 — 其他渠道 (P3)

| # | 任务 | 负责 | 说明 |
|---|------|------|------|
| 23.1 | iMessage 渠道 | Backend | macOS AppleScript/JXA |
| 23.2 | Google Chat 渠道 | Backend | Google Workspace API |
| 23.3 | Line 渠道 | Backend | Line Messaging API |
| 23.4 | 多账户支持 | Backend | 同渠道多账户切换 |
| 23.5 | QR 码登录 | Backend | 渠道登录扫码 |

---

## Sprint 24 — 收尾 & 打磨 (P3)

| # | 任务 | 负责 | 说明 |
|---|------|------|------|
| 24.1 | apply_patch 工具 | Backend | 多文件统一补丁 |
| 24.2 | Cron CLI 补全 | Backend | `cex cron` 子命令 |
| 24.3 | 命令自动补全 | Backend | bash/zsh/fish |
| 24.4 | 自更新 | Backend | `cex update` |
| 24.5 | 引导向导 | Backend | `cex onboard` 首次使用 |

---

## 总览甘特图

```
Sprint 8  ████ Sessions/Subagent 补完        [P0]
Sprint 9  ████ 安全系统基础                   [P0]
Sprint 10 ████ Web 管理界面补完               [P1]
Sprint 11 ██████████ CLI 命令补全 (17项)      [P1]
Sprint 12 ██ AI 提供商扩展                    [P1]
Sprint 13 ███ Signal + Slack 渠道             [P1]
Sprint 14 ████ Gateway 服务完善               [P1]
Sprint 15 ████ TUI 终端界面                   [P2]
Sprint 16 ██ 配置系统完善                     [P2]
Sprint 17 ██ 浏览器增强                       [P2]
Sprint 18 ███ 插件系统                        [P2]
Sprint 19 ██ Skills 系统                      [P2]
Sprint 20 ██ Hooks/Webhooks                   [P2]
Sprint 21 ██ 日志 & 记忆补全                  [P2]
Sprint 22 █ 节点补完                          [P2]
Sprint 23 ███ 其他渠道                        [P3]
Sprint 24 ██ 收尾打磨                         [P3]
```

## 里程碑

| 里程碑 | 包含 Sprint | 目标 |
|--------|------------|------|
| **M1: 生产可用** | 8-9 | 子代理闭环 + 安全基础 |
| **M2: 日常好用** | 10-14 | Web + CLI + 渠道 + AI 完整 |
| **M3: 功能完整** | 15-22 | TUI + 插件 + Skills + 所有 P2 |
| **M4: 全面对等** | 23-24 | 与 OpenClaw 功能 1:1 |

---

## 决策记录

| 日期 | 决策 | 原因 |
|------|------|------|
| 2026-03-24 | WhatsApp 从需求中移除 | 老板指示 |
| 2026-03-24 | Sandbox 降级到 Sprint 9（安全系统内） | 老板指示，与安全整体规划 |
| 2026-03-24 | A2A + Always-On 优先于 TUI | 多 Agent 协作是核心竞争力 |

