# ClawdEx 下一阶段开发路线图

> **当前状态**: v0.3.3, ~47% 完成度 (99/209 功能)  
> **目标**: 提升用户体验，增强核心功能，扩展渠道覆盖

---

## 📊 现状分析

### ✅ 已完成核心功能
- 基础工具系统 (22/24 工具)
- WebChat 管理界面 (8 页面)
- 会话 & 子代理系统
- AI 模型集成 (5 个提供商)
- 浏览器自动化 (CDP)
- 渠道支持 (Telegram, Discord, WebChat)

### 🎯 关键缺失 (P1 优先级)
1. **TUI 终端界面** — 开发者主要交互方式
2. **WhatsApp/Signal 渠道** — 用户常用即时通信
3. **CLI 命令集** — 部署运维必需
4. **Sandbox 安全模式** — 生产环境必需
5. **子代理功能完善** — cleanup/label/thinking 支持

---

## 🚀 Sprint 3: CLI 基础设施 (目标: 完善开发者体验)

**Sprint 目标**: 实现基础 CLI 命令和健康检查系统，让开发者能快速诊断问题

| 任务 | 负责角色 | 工作量 | 依赖 |
|------|----------|--------|------|
| **CLI status/health 命令** | Backend Dev | M | - |
| **CLI configure 向导** | Backend Dev | L | CLI 基础 |
| **健康检查系统完善** | Backend Dev | M | - |
| **Web 健康面板** | Frontend Dev | S | 健康检查 API |
| **子代理 cleanup/label 支持** | Backend Dev | M | - |

**验收标准**:
- ✅ `clawd_ex status` 显示系统概览
- ✅ `clawd_ex health --verbose` 7项检查通过
- ✅ `clawd_ex configure` 交互式配置
- ✅ Web Dashboard 实时健康状态
- ✅ sessions_spawn 支持 cleanup: delete/keep

---

## 📱 Sprint 4: TUI 界面 & 渠道扩展 (目标: 用户交互体验)

**Sprint 目标**: 实现终端界面和关键即时通信渠道，大幅提升用户使用便利性

| 任务 | 负责角色 | 工作量 | 依赖 |
|------|----------|--------|------|
| **TUI 终端聊天界面** | UI Dev | XL | CLI 基础 |
| **WhatsApp 渠道集成** | Backend Dev | L | 渠道框架 |
| **Signal 渠道集成** | Backend Dev | L | 渠道框架 |
| **TUI 流式响应显示** | UI Dev | M | TUI 基础 |
| **渠道账户管理 UI** | Frontend Dev | M | Web 基础 |

**验收标准**:
- ✅ `clawd_ex tui` 启动终端聊天
- ✅ TUI 支持流式响应、工具调用显示
- ✅ WhatsApp webhook/API 消息收发
- ✅ Signal CLI 集成通信
- ✅ Web UI 管理多渠道账户

---

## 🛡️ Sprint 5: 安全 & 生产就绪 (目标: 企业级部署)

**Sprint 目标**: 实现安全模式和生产环境必需功能，确保企业部署可靠性

| 任务 | 负责角色 | 工作量 | 依赖 |
|------|----------|--------|------|
| **Sandbox 安全模式** | DevOps | XL | Docker 集成 |
| **Gateway 认证系统** | Backend Dev | L | Gateway 框架 |
| **工具权限控制** | Backend Dev | M | 安全框架 |
| **日志文件系统** | Backend Dev | S | - |
| **配置热重载** | Backend Dev | M | 配置系统 |

**验收标准**:
- ✅ Docker sandbox 模式隔离执行
- ✅ Gateway token/password 认证
- ✅ 工具黑白名单权限控制
- ✅ 持久化日志文件 + Web 查看器
- ✅ 配置修改无需重启服务

---

## 📈 优先级决策逻辑

### P1 功能排序依据:
1. **开发者频次** - CLI 和 TUI 是日常主要交互方式
2. **用户覆盖** - WhatsApp/Signal 比 Slack/Line 用户更多
3. **生产必需** - Sandbox 安全是企业部署的前提
4. **依赖关系** - CLI 基础 → TUI 界面 → 安全功能

### 工作量分布:
- **Sprint 3**: 2.5人·周 (基础设施)
- **Sprint 4**: 3.5人·周 (用户体验)  
- **Sprint 5**: 3.0人·周 (企业级)

### 风险控制:
- TUI 界面技术复杂度高，预留缓冲时间
- WhatsApp API 可能有限制，准备降级方案
- Sandbox 安全涉及 Docker，需要运维支持

---

## 🔄 后续规划 (Sprint 6+)

### 高价值功能:
- **多阶段输出系统** - 实时进度反馈
- **任务管理器** - 持久化任务队列
- **A2A 通信** - Agent 间协作
- **插件系统** - 第三方扩展

### 生态扩展:
- **更多 AI 模型** (Ollama, Groq, Qwen)
- **Skills 技能系统** - 复用 OpenClaw 技能
- **Hooks/Webhooks** - 外部系统集成

---

## 📋 实施注意事项

### 技术债务:
- 当前测试覆盖 392 个，需要保持测试先行
- FEATURES.md 中部分 🚧 状态需要澄清实际完成度
- 某些工具可能实际完成但标记错误

### 团队协作:
- Backend 和 Frontend 任务并行开发
- CLI/TUI 可能需要新的依赖库调研
- 渠道集成需要申请相应 API 权限

### 质量保证:
- 每个 Sprint 结束需要完整的回归测试
- 新功能必须包含单元测试和集成测试
- 关键路径需要端到端验证

---

*路线图版本: v1.0*  
*更新日期: 2026-03-17*  
*下次评估: Sprint 3 完成后*