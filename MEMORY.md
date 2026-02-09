# ClawdEx 经验与笔记

## Telegram 配置说明

ClawdEx 和 OpenClaw 使用**不同的 bot**，不存在 polling 冲突：
- OpenClaw: `@hemiassist_bot` (7954072689)
- ClawdEx: `@openclaw_ex_bot` (8486685040)

各自 polling 自己的 token，互不干扰。

---

## 浏览器使用故障排除

### 问题：浏览器启动失败或无响应

**症状：**
- `Browser` 工具的 `status` 显示浏览器已运行（端口 9222），但实际无法使用
- 尝试打开标签页或导航时失败

**解决方案：**
1. 先终止旧的 Chrome 进程：
   ```bash
   pkill -f chrome
   ```
2. 重新启动浏览器：
   - 使用 `Browser` 工具，action: `start`

**记录日期：** 2026-02-09

---

