// cmd-notify —— Command Code 场景化桌面提醒（Windows）
//
// 按 AgentEvent 分场景弹不同的 Windows 通知：
//   done        绿 · 任务完成 / Task finished
//   error       红 · 运行出错 / Run failed
//   denied      橙 · 权限被拒 / Permission denied
//   subagent    蓝 · 子代理结束 / Subagent finished
//   compact     紫 · 上下文压缩 / Context compacted
//   retry       黄 · 接口重试 / API retry
//   interrupted 灰 · 已中断 / Interrupted
//
// 文案语言由 notify.ps1 决定（跟随系统界面语言，可用 notify.config.json 的 lang 覆盖）。
// 本文件只负责把结构化数据传过去，不拼人话。
//
// 全部静音：建一个空的 ~/.commandcode/hooks/notify.off
// 关掉某几类：~/.commandcode/hooks/notify.config.json 写 {"disabled": ["retry","compact"]}

import {spawn} from 'node:child_process';
import {existsSync, readFileSync, statSync} from 'node:fs';
import {homedir} from 'node:os';
import {basename, join} from 'node:path';

const HOOKS_DIR = join(homedir(), '.commandcode', 'hooks');
const SCRIPT = join(HOOKS_DIR, 'notify.ps1');
const CONFIG = join(HOOKS_DIR, 'notify.config.json');

// 无头模式（cmd -p）退出得很快，必须等通知跑完；TUI 里则不用等
const HEADLESS = process.argv.some(
	(a) => a === '-p' || a === '--print' || a.startsWith('--print='),
);

let disabled = new Set<string>();
let configStamp = -1;

function refreshConfig(): void {
	try {
		if (!existsSync(CONFIG)) {
			disabled = new Set();
			return;
		}
		const stamp = statSync(CONFIG).mtimeMs;
		if (stamp === configStamp) return;
		configStamp = stamp;
		const parsed = JSON.parse(readFileSync(CONFIG, 'utf8'));
		disabled = new Set(Array.isArray(parsed?.disabled) ? parsed.disabled : []);
	} catch {
		// 配置写坏了就当没配
	}
}

let lastKey = '';
let lastAt = 0;

/** 弹一条通知。数据走 base64，避开命令行引号转义。 */
function fire(scenario: string, data: Record<string, unknown>, project: string): Promise<void> {
	refreshConfig();
	if (disabled.has(scenario)) return Promise.resolve();
	if (!existsSync(SCRIPT)) return Promise.resolve();

	// 同场景同数据 2 秒内不重复
	const encoded = Buffer.from(JSON.stringify(data ?? {}), 'utf8').toString('base64');
	const key = `${scenario}|${encoded}`;
	const now = Date.now();
	if (key === lastKey && now - lastAt < 2000) return Promise.resolve();
	lastKey = key;
	lastAt = now;

	return new Promise<void>((resolve) => {
		let settled = false;
		const done = (): void => {
			if (settled) return;
			settled = true;
			resolve();
		};

		try {
			// 注意：不能用 detached —— 本机 detached 的子进程会空跑退出
			const child = spawn(
				'powershell.exe',
				[
					'-NoProfile',
					'-ExecutionPolicy',
					'Bypass',
					'-File',
					SCRIPT,
					'-Scenario',
					scenario,
					'-Data64',
					encoded,
					'-Project',
					project,
				],
				{stdio: 'ignore', windowsHide: true},
			);
			child.on('error', done);
			child.on('exit', done);
		} catch {
			// 提醒失败绝不影响主流程
		}

		if (!HEADLESS) {
			done(); // TUI 里不等，进程会活着把子进程跑完
		} else {
			setTimeout(done, 10_000); // 兜底，别把 CLI 卡死
		}
	});
}

function totalTokens(usage: any): number {
	if (!usage || typeof usage !== 'object') return 0;
	if (typeof usage.totalTokens === 'number') return usage.totalTokens;
	const input = Number(usage.inputTokens ?? usage.input_tokens ?? 0) || 0;
	const output = Number(usage.outputTokens ?? usage.output_tokens ?? 0) || 0;
	return input + output;
}

function snippet(text: unknown, max = 90): string {
	if (typeof text !== 'string') return '';
	const flat = text.replace(/\s+/g, ' ').trim();
	if (!flat) return '';
	return flat.length > max ? `${flat.slice(0, max)}…` : flat;
}

export default function (cmd: any): void {
	const project = (): string => {
		try {
			return basename(String(cmd?.cwd ?? '')) || 'Command Code';
		} catch {
			return 'Command Code';
		}
	};

	let errorNotified = false;
	cmd.on('run_start', () => {
		errorNotified = false;
	});

	// 一轮对话结束：完成 / 出错 / 被中断
	// 用 onRunEnd（会被 await）而不是 run_end 事件，保证 -p 模式下通知也发得出去
	cmd.hooks({
		onRunEnd: async ({result}: any) => {
			const reason = String(result?.stopReason ?? 'end_turn');
			const data = {
				turns: Number(result?.turnCount ?? 0),
				tokens: totalTokens(result?.usage),
				snippet: snippet(result?.finalText),
			};

			if (reason === 'error') {
				if (errorNotified) return; // run_error 已经弹过
				await fire('error', data, project());
			} else if (reason === 'interrupted') {
				await fire('interrupted', data, project());
			} else {
				await fire('done', data, project());
			}
		},
	});

	// 非重试性故障
	cmd.on('run_error', (ev: any) => {
		errorNotified = true;
		void fire(
			'error',
			{snippet: snippet(ev?.error?.message ?? ev?.error ?? ev?.message, 110)},
			project(),
		);
	});

	// 权限被拒 —— 通常意味着在等你放行
	cmd.on('tool_denied', (ev: any) => {
		void fire('denied', {tool: ev?.toolName ?? ev?.tool_name ?? ev?.tool ?? ''}, project());
	});

	// 子代理（agent 工具）跑完
	cmd.on('subagent_stop', (ev: any) => {
		void fire(
			'subagent',
			{
				subagentType: ev?.subagentType ?? ev?.subagent_type ?? '',
				tokens: Number(ev?.tokensUsed ?? ev?.tokens_used ?? 0) || 0,
			},
			project(),
		);
	});

	// 上下文压缩完成
	cmd.on('compaction_done', (ev: any) => {
		void fire('compact', {saved: Number(ev?.tokensSaved ?? ev?.tokens_saved ?? 0) || 0}, project());
	});

	// 接口在重试（限流 / 网络抖动）
	cmd.on('api_retry', (ev: any) => {
		void fire(
			'retry',
			{
				attempt: Number(ev?.attempt ?? 0) || 0,
				delay: Number(ev?.delayMs ?? ev?.delay_ms ?? 0) || 0,
				detail: snippet(ev?.error?.message ?? ev?.error, 80),
			},
			project(),
		);
	});
}
