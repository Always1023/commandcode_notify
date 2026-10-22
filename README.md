# cmd-notify

Command Code 的场景化桌面提醒。按事件类型弹出不同颜色、不同声音的 Windows 通知，用于在长任务期间判断「跑完了」「出错了」「在等你放行」。

## 背景

Command Code 的扩展机制是 mods。内置 mod 共七项（`provider-copilot`、`provider-openai`、`provider-anthropic`、`update-notice`、`acp`、`peek`、`herdr`），没有通知类；shell hooks 只有 `PreToolUse`、`PostToolUse`、`Stop`、`SessionStart` 四个事件，也没有 `Notification` 事件。

本项目用 mod 订阅 `AgentEvent` 流补齐这块：会话内的事件走 `cmd.on()`，会话结束走会被 await 的 `onRunEnd` 钩子。

## 场景与样式

| 场景 | 触发事件 | 标题 | 徽标底色 | 声音 |
|---|---|---|---|---|
| `done` | 一轮对话正常结束 | ✅ 任务完成 | 绿 | Notification.Default |
| `error` | `run_error`，或 `stopReason` 为 `error` | ❌ 运行出错 | 红 | Notification.Reminder |
| `denied` | `tool_denied` | 🚫 权限被拒 | 橙 | Notification.IM |
| `subagent` | `subagent_stop` | 🤖 子代理结束 | 蓝 | Notification.Mail |
| `compact` | `compaction_done` | 🗜️ 上下文压缩 | 紫 | Notification.SMS |
| `retry` | `api_retry` | ⏳ 接口重试 | 黄 | Notification.Reminder |
| `interrupted` | `stopReason` 为 `interrupted` | ⏹️ 已中断 | 灰 | 无 |

正文带关键信息：完成时是「轮数 · token 用量」加最后一句回复的摘要；重试时是「第几次 · 多久后重试」加错误原因；权限被拒时是工具名。

## 安装

前置条件：Windows 10 或 11、Command Code 1.82 及以上（实测 1.82.0）、Windows PowerShell 5.1。

```powershell
git clone https://github.com/Always1023/commandcode_notify.git
cd commandcode_notify
.\install.ps1
```

`install.ps1` 做三件事：把 mod 复制到 `~/.commandcode/mods/`，把通知脚本复制到 `~/.commandcode/hooks/`，跑一次自检（只写日志，不弹窗）。

重启 Command Code 生效。确认方式：

```powershell
commandcode mods list
```

输出中出现 `cmd-notify · user` 即安装成功。

## 验证

自检不打扰桌面：

```powershell
& "$env:USERPROFILE\.commandcode\hooks\notify.ps1" -Scenario done -Project "自检" -DryRun
Get-Content "$env:USERPROFILE\.commandcode\hooks\notify.log" -Tail 1
```

去掉 `-DryRun` 会真的弹一条通知，可用来确认颜色和声音。

无头模式可以端到端验证：

```powershell
commandcode -p "只回复两个字：收到" --max-turns 2
```

## 配置

配置与运行数据都在 `~/.commandcode/hooks/`。

| 需求 | 做法 |
|---|---|
| 全部静音 | 建空文件 `~/.commandcode/hooks/notify.off`，删掉即恢复 |
| 关闭部分场景 | `notify.config.json` 写 `{"disabled":["retry","compact","subagent"]}` |
| 固定标题里的项目名 | `notify.config.json` 写 `{"label":"我的项目"}` |

默认标题里的项目名取自 `cmd.cwd` 的目录名，超过 26 个字符截断。

## 自定义样式

颜色、图形、声音和标题文案在 `hooks/notify.ps1` 顶部的 `$scenes` 表。徽标是首次运行时用 `System.Drawing` 画出来的 PNG，缓存于 `~/.commandcode/hooks/badges/`，改完样式后删除该目录即可重画。

## 已知限制

- 仅支持 Windows。依赖 WinRT toast 与 `System.Drawing`。
- 通知借 Windows PowerShell 的 AppID 发出。系统设置里关闭 PowerShell 的通知后，提醒不可见。
- 通知中心里的历史记录无法用 `ToastNotificationManager.History.Clear()` 清除（该接口要求注册过的 AppID），需要手动关闭或使用「清除全部」。
- TUI 下不等待通知进程结束；`cmd -p` 下会等待，否则通知进程会随父进程一起退出。
- 走 mod 事件流而非 shell hooks，因此 plan 模式下仍会提醒（shell hooks 在 plan 模式会被完全跳过）。

## 卸载

```powershell
.\uninstall.ps1          # 移除 mod 与通知脚本，保留配置和徽标
.\uninstall.ps1 -All     # 连配置、徽标和日志一起删
```

## 目录结构

```
commandcode_notify/
├── install.ps1           安装脚本
├── uninstall.ps1         卸载脚本
├── mods/cmd-notify.ts    mod 本体，订阅事件
├── hooks/notify.ps1      发通知，画徽标
└── examples/notify.config.json   配置样例
```
## 许可

MIT，见 [LICENSE](LICENSE)。
