# ClawdEx 开发路线图

## 目标
实现与 OpenClaw 功能对等的 Elixir 版本。

## 阶段规划

### Phase 1: 核心工具 ✅
- [x] read, write, edit
- [x] exec, process
- [x] web_search, web_fetch
- [x] compact

### Phase 2: 会话与代理系统 ✅
- [x] **sessions_list** - 列出会话
- [x] **sessions_history** - 会话历史
- [x] **sessions_send** - 跨会话消息
- [x] **sessions_spawn** - 子代理生成
- [x] **agents_list** - 代理列表
- [x] **session_status** - 会话状态

### Phase 3: 自动化系统 ✅
- [x] **cron** - 定时任务管理 (Job schema + migration)
- [x] **gateway** - 自管理 (restart/config)
- [x] **message** - 多渠道消息工具

### Phase 4: 浏览器控制 ✅
- [x] **browser** 基础架构
  - [x] Chrome DevTools Protocol 集成
  - [x] start/stop/status
  - [x] tabs 管理 (open/close)
- [x] **browser** 页面操作
  - [x] snapshot (aria/ai)
  - [x] screenshot
  - [x] navigate/console
- [x] **browser** 自动化
  - [x] act (click/type/press/hover/select/fill/drag/wait)
  - [x] evaluate (JS 执行)
  - [x] upload/dialog

### Phase 5: 节点系统 ✅
- [x] **nodes** 基础
  - [x] 节点发现与配对
  - [x] status/describe/pending/approve/reject
- [x] **nodes** 功能
  - [x] notify (通知)
  - [x] run (远程执行)
  - [x] camera_snap/camera_list/camera_clip
  - [x] screen_record
  - [x] location_get

### Phase 6: Canvas/A2UI ✅
- [x] **canvas** 工具
  - [x] present/hide/navigate
  - [x] eval/snapshot
  - [x] a2ui_push/a2ui_reset

### Phase 7: OAuth 认证 ✅
- [x] **OAuth 凭证管理** (GenServer)
  - [x] 自动 token 刷新 (过期前 5 分钟)
  - [x] Claude CLI 凭证加载 (`~/.claude/.credentials.json`)
  - [x] 凭证持久化 (`~/.clawd_ex/oauth_credentials.json`)
- [x] **Anthropic OAuth** 
  - [x] Token 刷新 (`console.anthropic.com/v1/oauth/token`)
  - [x] PKCE 登录流程支持
  - [x] Claude Code 兼容 headers
  - [x] System prompt 前缀

### Phase 8: WebChat 管理界面 ✅
- [x] **Phoenix LiveView 界面**
  - [x] 侧边栏导航布局
  - [x] 深色主题 UI
- [x] **Dashboard 页面**
  - [x] 系统统计 (Agents/Sessions/Messages)
  - [x] 最近会话列表
  - [x] 最近消息列表
  - [x] 快捷操作
- [x] **Chat 页面**
  - [x] 实时聊天界面
  - [x] 流式响应显示
  - [x] 工具调用历史展示
  - [x] 会话切换与历史加载
  - [x] 完全异步消息发送 (PubSub)
- [x] **Sessions 管理**
  - [x] 会话列表 (分页/筛选/搜索)
  - [x] 会话详情 (消息历史)
  - [x] Archive/Delete 操作
  - [x] 消息数实时计算
- [x] **Agents 管理**
  - [x] Agent 列表
  - [x] Agent 创建/编辑/删除
  - [x] Model 选择
  - [x] System Prompt 配置
- [x] **组件化架构**
  - [x] 独立 .html.heex 模板
  - [x] 可复用组件 (stat_card, message_card, role_badge 等)

### Phase 9: 稳定性增强 ✅
- [x] **AI API 重试机制** (3次，指数退避)
- [x] **工具调用上限** (50次/run，防止无限循环)
- [x] **超时防崩溃** (safe_run_agent 包装)
- [x] **UTF-8 输出清理** (sanitize_output)
- [x] **LiveView 心跳超时修复** (完全异步 PubSub)

### Phase 10: P0 核心体验 ✅
- [x] **CLI 基础命令**
  - [x] status - 应用状态概览
  - [x] health - 综合健康检查 (7 项)
  - [x] configure - 交互式配置向导
  - [x] escript 支持
- [x] **健康检查系统**
  - [x] Database (连接/延迟/大小)
  - [x] Memory (总量/进程/系统)
  - [x] Processes (数量/限制)
  - [x] AI Providers (配置状态)
  - [x] Browser (Chrome 可用性)
  - [x] Filesystem (工作区可写)
  - [x] Network (DNS 连通性)
- [x] **Cron 管理界面**
  - [x] 任务列表 (筛选/统计)
  - [x] 创建/编辑任务
  - [x] 任务详情 + 运行历史
  - [x] 手动运行/启用禁用
- [x] **Cron 执行系统** (CronExecutor)
  - [x] system_event 模式 - 注入消息到已有 session
  - [x] agent_turn 模式 - 隔离 session 执行
  - [x] 目标渠道投递 (telegram/discord/webchat)
  - [x] Session 自动清理 (cleanup: delete/keep)
  - [x] Session 选择器 (自动填充活跃 sessions)
- [x] **日志查看器**
  - [x] 日志文件选择
  - [x] 级别过滤 (error/warn/info/debug)
  - [x] 文本搜索
  - [x] 自动刷新
- [x] **配置编辑器**
  - [x] 通用配置
  - [x] AI 提供商状态
  - [x] 环境变量管理
  - [x] 系统信息展示
- [x] **Dashboard 健康面板**
  - [x] 实时健康状态显示
  - [x] 7 项子系统检查

---

## 当前状态

### ✅ 已完成 (Phase 1-10)
- **核心框架**: Agent Loop, Sessions, Memory
- **基础工具**: read/write/edit/exec/process
- **记忆系统**: BM25 + Vector hybrid, 中文支持
- **流式响应**: Block Streaming, 代码块保护
- **会话压缩**: AI 摘要自动压缩
- **渠道**: Telegram (Telegex), Discord (Nostrum), WebChat (LiveView)
- **会话管理**: sessions_list/history/send/spawn, agents_list
- **自动化**: cron (完整执行系统), gateway, message
- **浏览器**: CDP 完整控制
- **节点**: 远程设备控制
- **画布**: Canvas/A2UI
- **OAuth**: Anthropic Claude OAuth token 自动刷新
- **WebChat**: 完整的 LiveView 管理界面 (8 页面)
- **稳定性**: 重试/超时/异步处理/空 session 复用
- **CLI**: status/health/configure 命令
- **健康检查**: 7 项子系统监控
- **Cron 执行**: system_event + agent_turn 双模式

### 📋 待开发 (按优先级)

**P0 - 核心体验:** ✅ 已完成

**P1 - 重要功能:**
- [ ] TUI 终端界面
- [x] 子代理完整功能 (cleanup/label/thinking/restriction)
- [ ] WhatsApp/Signal 渠道
- [ ] Sandbox 安全模式

**P2 - 增强功能:**
- [ ] 更多 AI 提供商 (Ollama/Groq/Qwen)
- [ ] 插件系统
- [ ] Skills 系统
- [ ] Hooks/Webhooks

详细功能对比见 [docs/FEATURES.md](docs/FEATURES.md)

### 📊 统计
- **整体完成度**: ~50% (89/181 功能)
- **工具数量**: 29 个
- **测试用例**: 903 个
- **渠道数量**: 3/11 个
- **AI 提供商**: 6 个 (Anthropic/OpenAI/Google/Groq/Ollama/OpenRouter)
- **LiveView 页面**: 11 个 (Dashboard/Chat/Sessions/Agents/Cron/Logs/Settings 等)
- **CLI 命令**: 12 个 (status/health/configure/sessions/agents/cron/models/logs/gateway/start/stop/version)

---

## 更新日志

### 2026-03-17 (v0.4.0) - 技术文档完善
- 📚 **技术文档**
  - 新增 `docs/API.md` - 完整 API 文档 (WebSocket/LiveView/CLI/AI Providers)
  - 新增 `docs/DEPLOYMENT.md` - 部署指南 (系统要求/快速开始/生产部署/Docker)
  - 涵盖所有 50+ 内置工具的使用说明
  - 详细的环境变量配置指南
- 🔧 **架构文档化**
  - Phoenix LiveView 页面路由完整说明 (`/`, `/chat`, `/sessions`, `/agents` 等)
  - WebSocket 实时通信协议规范
  - CLI 命令行接口完整参考
  - AI 提供商配置文档 (OpenRouter/Ollama/Groq)
- 🚀 **部署优化**
  - 系统要求明确化 (Elixir 1.19+, PostgreSQL 14+, pgvector)
  - Systemd 服务配置示例
  - Nginx 反向代理配置
  - Docker 容器化部署方案
  - 故障排查和维护指南
- ✅ **文档工程**: API 文档、部署指南、运维手册

### 2026-02-09 (v0.3.3) - Prompt System & Memory Refactor
- 🔧 **Prompt 系统重构**
  - 移植 OpenClaw 风格的 prompt 系统
  - 添加 "CRITICAL: Use Tools, Don't Pretend" 章节
  - 修复 Agent Loop 伪工具调用问题
- 🧠 **记忆系统重构**
  - 单后端模型 (single-backend-per-agent)
  - 统一记忆系统多后端支持
- 📱 **Telegram 增强**
  - 统一消息段处理
  - 自动检测图片路径并发送
  - Markdown 路径包装检测优化
  - 持续打字指示器
- ✅ **测试**: 387 tests, 0 failures

### 2026-02-03 (v0.3.2) - Cron Execution System
- ⏰ **完整 Cron 执行系统** (`CronExecutor`)
  - system_event 模式: 注入消息到已有 session
  - agent_turn 模式: 隔离 session + AI 执行 + 自动清理
  - 目标渠道投递 (telegram/discord/webchat)
  - Session 选择器下拉框 (活跃 sessions)
- 🔧 **WebChat 优化**
  - 空 session 复用 (防止刷新爆炸)
  - Run Now 刷新修复
- ✅ **测试**: Cron agent_turn 端到端通过 (AI 响应 "4")

### 2026-02-03 (v0.3.1) - P0 Core Experience
- ✨ **CLI 命令**
  - `status` - 应用状态概览
  - `health --verbose` - 7 项综合健康检查
  - `configure` - 交互式配置向导
  - escript 独立可执行文件支持
- 🏥 **健康检查系统** (`ClawdEx.Health`)
  - Database / Memory / Processes / AI Providers
  - Browser / Filesystem / Network
  - Dashboard 实时健康面板
- ⏰ **Cron 管理界面** (`/cron`)
  - 任务列表、创建/编辑、详情
  - 运行历史、手动触发、启用/禁用
- 📜 **日志查看器** (`/logs`)
  - 文件选择、级别过滤、文本搜索
  - 自动刷新、清空日志
- ⚙️ **配置编辑器** (`/settings`)
  - 通用配置、AI 提供商状态
  - 环境变量、系统信息
- ✅ **测试**: 377 tests, 0 failures

### 2026-02-03 (v0.3.0) - WebChat UI
- ✨ **完整的 LiveView 管理界面**
  - Dashboard 系统概览
  - Chat 实时聊天
  - Sessions 会话管理
  - Agents CRUD
- 🔧 **异步架构重构**
  - 完全异步消息发送 (GenServer.cast + PubSub)
  - 解决 LiveView 心跳超时问题
- 🛡 **稳定性增强**
  - AI API 重试机制 (3次，指数退避)
  - 工具调用上限 50 次/run
  - UTF-8 输出清理
  - 超时防崩溃
- 🎨 **UI/UX**
  - 深色主题
  - 侧边栏导航
  - 组件化模板 (.html.heex)
- ✅ **测试**: 377 tests, 0 failures

### 2026-01-31 (v0.2.1) - OAuth 支持
- ✨ **OAuth Token 支持**
  - `ClawdEx.AI.OAuth` GenServer 凭证管理
  - `ClawdEx.AI.OAuth.Anthropic` token 刷新
  - 自动检测 OAuth token (`sk-ant-oat*`)
  - Claude CLI 凭证加载
  - 凭证持久化
- 🔧 **流式 API 修复**
  - 修复 Req 0.5.x async response 格式
  - 修复 OAuth headers accept 冲突
- ✅ **测试**: 318 tests, 0 failures
- 🧪 **闭环验证**: Agent Loop + Browser 自动化通过

### 2026-01-31 (v0.2.0) - 功能完成
- 🎉 **里程碑**: 所有主要功能阶段完成
- Phase 6: Canvas/A2UI 工具
- Phase 5: 节点系统 (notify/run/camera/screen/location)
- Phase 4: 浏览器控制 (CDP, 完整自动化)
- Phase 3: 自动化系统 (cron/gateway/message)
- Phase 2: 会话与代理系统
- 优化: 记忆系统中文分词, 流式响应

### 2026-01-30 (v0.1.0)
- 初始路线图创建
- Phase 1 核心工具完成
- 基础框架搭建

---

## 技术亮点

### 完全异步消息处理
```
User Message → ChatLive → SessionWorker.send_message_async (cast)
                                ↓
                         Task.start (background)
                                ↓
                         AgentLoop.run
                                ↓
                         PubSub.broadcast("session:#{key}")
                                ↓
ChatLive ← handle_info({:agent_result, result})
```

### Agent Loop 状态机
```
:idle → :preparing → :inferring → :executing_tools → :inferring → ...
                                        ↓
                              tool_iterations++ (max 50)
                                        ↓
                              回到 :idle 时重置为 0
```

### 浏览器自动化
```elixir
browser(start) → browser(open, url) → browser(screenshot, targetId) → 截图保存
```
