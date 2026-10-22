# cmd-notify

Scenario-aware desktop notifications for Command Code. During a long run, you get a Windows toast whose color and sound tell you what just happened: finished, failed, or waiting for your approval.

[中文](README.md) | **English**

## Why this exists

Command Code extends itself through mods. The seven built-in mods (`provider-copilot`, `provider-openai`, `provider-anthropic`, `update-notice`, `acp`, `peek`, `herdr`) include nothing for notifications, and the shell hooks only cover `PreToolUse`, `PostToolUse`, `Stop` and `SessionStart` — there is no `Notification` event.

This project fills that gap with a mod that subscribes to the `AgentEvent` stream: in-session events go through `cmd.on()`, and the end of a run goes through the awaited `onRunEnd` hook.

## Scenarios

| Scenario | Trigger | Title (English / 中文) | Badge color | Sound |
|---|---|---|---|---|
| `done` | a turn ends normally | ✅ Task finished / 任务完成 | green | Notification.Default |
| `error` | `run_error`, or `stopReason` is `error` | ❌ Run failed / 运行出错 | red | Notification.Reminder |
| `denied` | `tool_denied` | 🚫 Permission denied / 权限被拒 | orange | Notification.IM |
| `subagent` | `subagent_stop` | 🤖 Subagent finished / 子代理结束 | blue | Notification.Mail |
| `compact` | `compaction_done` | 🗜️ Context compacted / 上下文压缩 | purple | Notification.SMS |
| `retry` | `api_retry` | ⏳ API retry / 接口重试 | yellow | Notification.Reminder |
| `interrupted` | `stopReason` is `interrupted` | ⏹️ Interrupted / 已中断 | gray | none |

The body carries the details: turn count, token usage and a snippet of the final reply for `done`; attempt number, delay and the error for `retry`; the tool name for `denied`.

## Language

Titles and bodies follow the system UI language: Chinese (`zh*`) gets Chinese text, everything else gets English. The language switches both the title and the body, not just the title.

Resolution order:

1. The `-Lang zh|en` command-line argument
2. The `lang` field in `notify.config.json`
3. System UI language, from `[System.Globalization.CultureInfo]::CurrentUICulture`

The same event in both languages:

```
[done/zh-CN] ✅ 任务完成 · QuotaTool :: 3 轮 · 23.4k tokens / 修复了登录超时的重试逻辑
[done/en]    ✅ Task finished · QuotaTool :: 3 turns · 23.4k tokens / 修复了登录超时的重试逻辑
```

The `[scenario/language]` prefix in each log line tells you which language is active.

## Install

Requirements: Windows 10 or 11, Command Code 1.82 or newer (tested on 1.82.0), Windows PowerShell 5.1.

```powershell
git clone https://github.com/Always1023/commandcode_notify.git
cd commandcode_notify
.\install.ps1
```

`install.ps1` does three things: copies the mod to `~/.commandcode/mods/`, copies the notification script to `~/.commandcode/hooks/`, and runs a self-test that only writes to the log.

Restart Command Code for the mod to load. Confirm with:

```powershell
commandcode mods list
```

`cmd-notify · user` in the output means it is installed.

## Verify

The self-test does not disturb your desktop:

```powershell
& "$env:USERPROFILE\.commandcode\hooks\notify.ps1" -Scenario done -Project "self-test" -DryRun
Get-Content "$env:USERPROFILE\.commandcode\hooks\notify.log" -Tail 1
```

Drop `-DryRun` to actually show a toast, which is how you check colors and sounds.

Headless end-to-end check:

```powershell
commandcode -p "reply with just: ok" --max-turns 2
```

## Configuration

Configuration and runtime data live in `~/.commandcode/hooks/`.

| Goal | How |
|---|---|
| Mute everything | Create an empty `~/.commandcode/hooks/notify.off`; delete it to restore |
| Disable some scenarios | `notify.config.json` with `{"disabled":["retry","compact","subagent"]}` |
| Pin the project name in titles | `notify.config.json` with `{"label":"my-project"}` |
| Force a language | `notify.config.json` with `{"lang":"en"}` or `{"lang":"zh"}` |

By default the project name in the title comes from the basename of `cmd.cwd`, truncated at 26 characters.

## Customizing

Colors, glyphs, sounds and titles are in the `$scenes` table at the top of `hooks/notify.ps1`. Each scenario has `Zh` and `En` title fields, so adding a language is one more column. Badges are PNGs drawn with `System.Drawing` on first run and cached in `~/.commandcode/hooks/badges/`; delete that directory to redraw them after changing styles.

## Limitations

- Windows only. Depends on WinRT toasts and `System.Drawing`.
- Toasts are sent under Windows PowerShell's AppID. If notifications for PowerShell are turned off in system settings, nothing shows up.
- Notification history cannot be cleared with `ToastNotificationManager.History.Clear()`, because that API requires a registered AppID. Dismiss entries manually or use "Clear all".
- In the TUI the mod does not wait for the notifier process; under `cmd -p` it does, otherwise the notifier would be killed together with its parent.
- Events are read from the mod stream rather than shell hooks, so notifications still fire in plan mode (shell hooks are skipped entirely there).

## Uninstall

```powershell
.\uninstall.ps1          # remove mod and notifier script, keep config and badges
.\uninstall.ps1 -All     # also remove config, badges and log
```

## Layout

```
commandcode_notify/
├── install.ps1           installer
├── uninstall.ps1         uninstaller
├── mods/cmd-notify.ts    the mod, subscribes to events
├── hooks/notify.ps1      shows toasts, draws badges
└── examples/notify.config.json   sample config
```

## License

MIT, see [LICENSE](LICENSE).
