// cmd-notify —— Command Code 场景化桌面提醒（Windows）
//
// 按 AgentEvent 分场景弹不同的 Windows 通知：
//   done        绿 · 任务完成
//   error       红 · 运行出错
//   denied      橙 · 权限被拒
//   subagent    蓝 · 子代理结束
//   compact     紫 · 上下文压缩
//   retry       黄 · 接口重试
//   interrupted 灰 · 已中断
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

/** 弹一条通知。headless 模式下返回可 await 的 Promise。 */
function fire(scenario: string, message: string, project: string): Promise<void> {
	refreshConfig();
	if (disabled.has(scenario)) return Promise.resolve();
	if (!existsSync(SCRIPT)) return Promise.resolve();

	// 同场景同文案 2 秒内不重复
	const key = `${scenario}|${message}`;
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
					'-Message',
					message,
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

function fmtTokens(n: unknown): string {
	const v = typeof n === 'number' ? n : Number(n);
	if (!Number.isFinite(v) || v <= 0) return '';
	if (v >= 1_000_000) return `${(v / 1_000_000).toFixed(1)}M tokens`;
	if (v >= 1000) return `${(v / 1000).toFixed(1)}k tokens`;
	return `${Math.round(v)} tokens`;
}

function usageOf(result: any): string {
	const u = result?.usage ?? {};
	const total =
		typeof u.totalTokens === 'number'
			? u.totalTokens
			: (Number(u.inputTokens ?? u.input_tokens ?? 0) || 0) +
				(Number(u.outputTokens ?? u.output_tokens ?? 0) || 0);
	return fmtTokens(total);
}

function snippet(text: unknown, max = 90): string {
	if (typeof text !== 'string') return '';
	const flat = text.replace(/\s+/g, ' ').trim();
	if (!flat) return '';
	return flat.length > max ? `${flat.slice(0, max)}…` : flat;
}

function joinLines(...parts: Array<string | undefined | false>): string {
	return parts.filter(Boolean).join('\n');
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
			const turns = Number(result?.turnCount ?? 0);
			const tokens = usageOf(result);
			const meta = [turns > 0 ? `${turns} 轮` : '', tokens].filter(Boolean).join(' · ');
			const tail = snippet(result?.finalText);

			if (reason === 'error') {
				if (errorNotified) return; // run_error 已经弹过
				await fire('error', joinLines(meta, tail || '运行以错误结束'), project());
			} else if (reason === 'interrupted') {
				await fire('interrupted', joinLines(meta, '已取消这次运行'), project());
			} else {
				await fire('done', joinLines(meta, tail), project());
			}
		},
	});

	// 非重试性故障
	cmd.on('run_error', (ev: any) => {
		errorNotified = true;
		const msg = snippet(ev?.error?.message ?? ev?.error ?? ev?.message, 110);
		void fire('error', msg || '发生未处理的错误', project());
	});

	// 权限被拒 —— 通常意味着在等你放行
	cmd.on('tool_denied', (ev: any) => {
		const tool = ev?.toolName ?? ev?.tool_name ?? ev?.tool;
		void fire('denied', tool ? `工具 ${tool} 被拒绝执行` : '有工具调用被拒绝执行', project());
	});

	// 子代理（agent 工具）跑完
	cmd.on('subagent_stop', (ev: any) => {
		const type = ev?.subagentType ?? ev?.subagent_type ?? '子代理';
		const tokens = fmtTokens(ev?.tokensUsed ?? ev?.tokens_used);
		void fire('subagent', joinLines(`${type} 已结束`, tokens), project());
	});

	// 上下文压缩完成
	cmd.on('compaction_done', (ev: any) => {
		const saved = fmtTokens(ev?.tokensSaved ?? ev?.tokens_saved);
		void fire('compact', saved ? `省下 ${saved}` : '上下文已压缩', project());
	});

	// 接口在重试（限流 / 网络抖动）
	cmd.on('api_retry', (ev: any) => {
		const attempt = Number(ev?.attempt ?? 0);
		const delay = Number(ev?.delayMs ?? ev?.delay_ms ?? 0);
		const detail = snippet(ev?.error?.message ?? ev?.error, 80);
		const meta = [
			attempt > 0 ? `第 ${attempt} 次` : '',
			delay > 0 ? `${Math.round(delay / 1000)}s 后重试` : '',
		]
			.filter(Boolean)
			.join(' · ');
		void fire('retry', joinLines(meta, detail), project());
	});
}
