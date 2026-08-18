/**
 * pi-fleet: multi-session quality-of-life for tmux fleets.
 *
 * 1. Session-summary titles: first user prompt names the session (manual /name wins).
 *    Title format: "π <marker> <name>" — tmux autorename shows it as the window name.
 * 2. Status marker in title: 🤖 while the agent works, 🟢 when it settled and waits
 *    for you, 🙋 when its last message asks you a question, 🆕 before the first run.
 * 3. Terminal bell on settle: tmux flags the window in the status bar.
 * 4. Idle recap widget: if you don't respond for a while after the agent settles,
 *    an AI recap (out-of-band `pi -p` call — never touches this session's history)
 *    is shown above the editor; falls back to a static recap. The recap model is
 *    the most balanced one the user has auth for (each provider's mid tier:
 *    sonnet, gpt-mini, flash, grok-fast, kimi, deepseek, qwen-plus, glm, mistral,
 *    haiku … else user default); override with PI_FLEET_RECAP_MODEL.
 * 5. /ref: pick another pi session and insert a pointer (name + transcript path)
 *    into the editor so this session's agent can read it when needed.
 * 6. tmux manual rename: renaming the window (prefix+, / prefix+R) normally sets
 *    automatic-rename off, freezing the name and losing the status marker. pi-fleet
 *    adopts the manual name as the session name and re-enables automatic-rename,
 *    so the marker comes back with your chosen name.
 *
 * Uninstall: rm ~/.pi/agent/extensions/pi-fleet.ts
 */

import { execFile } from "node:child_process";
import path from "node:path";
import { SessionManager } from "@earendil-works/pi-coding-agent";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

function age(date: Date): string {
	const mins = Math.round((Date.now() - date.getTime()) / 60000);
	if (mins < 60) return `${mins}m`;
	if (mins < 60 * 24) return `${Math.round(mins / 60)}h`;
	return `${Math.round(mins / (60 * 24))}d`;
}

const MAX_WORDS = 6;
const MAX_CHARS = 40;
const IDLE_RECAP_MS = Number(process.env.PI_FLEET_RECAP_MS) || 4 * 60 * 1000;
// Hardcoded recap model
const RECAP_MODEL = "deepseek/deepseek-v4-flash";

function summarize(prompt: string): string | undefined {
	const text = prompt.replace(/\s+/g, " ").trim();
	if (!text) return undefined;
	let summary = text.split(" ").slice(0, MAX_WORDS).join(" ");
	if (summary.length > MAX_CHARS) summary = `${summary.slice(0, MAX_CHARS - 1)}…`;
	return summary;
}

function truncate(text: string, max = 80): string {
	const clean = text.replace(/\s+/g, " ").trim();
	return clean.length > max ? `${clean.slice(0, max - 1)}…` : clean;
}

function textOf(message: { content?: unknown }): string {
	const content = message?.content;
	if (typeof content === "string") return content;
	if (Array.isArray(content)) {
		return content
			.filter((b) => b && typeof b === "object" && (b as { type?: string }).type === "text")
			.map((b) => (b as { text?: string }).text ?? "")
			.join(" ");
	}
	return "";
}

export default function (pi: ExtensionAPI) {
	let marker = "🆕";
	let lastAssistantAsks = false;
	let lastUser = "";
	let lastAssistant = "";
	let idleTimer: ReturnType<typeof setTimeout> | null = null;
	let titleTimers: ReturnType<typeof setTimeout>[] = [];
	let stopped = false; // ctx is stale after session_shutdown; never touch ctx.ui again
	let settledAt = 0;
	let recapGen = 0;
	let recapModel: string | null | undefined; // undefined = unresolved; null = use pi default
	const recent: string[] = []; // rolling transcript excerpt for the AI recap

	const resolveRecapModel = (_ctx: ExtensionContext): string => {
		return process.env.PI_FLEET_RECAP_MODEL || RECAP_MODEL;
	};

	const remember = (role: string, text: string) => {
		const clean = truncate(text, 400);
		if (!clean) return;
		recent.push(`${role}: ${clean}`);
		if (recent.length > 8) recent.shift();
	};

	const displayName = () => pi.getSessionName() ?? path.basename(process.cwd());

	// If the tmux window was manually renamed, tmux sets automatic-rename off and the
	// window name freezes (status marker gone for good). Adopt the manual name as the
	// session name (manual name wins) and re-enable automatic-rename so the marker returns.
	const adoptTmuxRename = (ctx: ExtensionContext) => {
		const pane = process.env.TMUX_PANE;
		if (!process.env.TMUX || !pane) return;
		execFile(
			"tmux",
			["display-message", "-p", "-t", pane, "#{automatic-rename}\t#{window_name}"],
			(err, stdout) => {
				if (err || stopped) return;
				const [auto, name = ""] = stdout.replace(/\n+$/, "").split("\t");
				if (auto !== "0") return; // window still follows the pane title
				const adopted = name.replace(/^(?:π\s+)?(?:[-⚙●?]|🤖|🟢|🙋|❓|🆕)\s+/u, "").trim();
				if (adopted && adopted !== displayName()) pi.setSessionName(adopted);
				execFile("tmux", ["set-option", "-w", "-t", pane, "automatic-rename", "on"], () => {
					if (!stopped) applyTitle(ctx);
				});
			},
		);
	};

	const applyTitle = (ctx: ExtensionContext) => {
		if (stopped) return;
		ctx.ui.setTitle(`π ${marker} ${displayName()}`);
		adoptTmuxRename(ctx);
	};

	const clearIdle = (ctx: ExtensionContext) => {
		if (idleTimer) clearTimeout(idleTimer);
		idleTimer = null;
		recapGen++;
		ctx.ui.setWidget("pi-fleet-recap", undefined);
	};

	pi.on("session_start", async (_event, ctx) => {
		applyTitle(ctx);
		// pi's TUI overwrites the title with its built-in one at the end of init,
		// which happens after this event: reassert ours once startup settles.
		titleTimers.push(setTimeout(() => applyTitle(ctx), 3000));
		titleTimers.push(setTimeout(() => applyTitle(ctx), 8000));
	});
	pi.on("session_info_changed", async (_event, ctx) => applyTitle(ctx));

	pi.on("before_agent_start", async (event, ctx) => {
		clearIdle(ctx);
		lastAssistantAsks = false;
		lastUser = truncate(event.prompt);
		remember("user", event.prompt);
		if (!pi.getSessionName()) {
			const summary = summarize(event.prompt);
			if (summary) pi.setSessionName(summary);
		}
	});

	pi.on("agent_start", async (_event, ctx) => {
		marker = "🤖";
		applyTitle(ctx);
	});

	pi.on("message_end", async (event) => {
		if (event.message.role === "assistant") {
			const text = textOf(event.message);
			if (text) {
				lastAssistant = truncate(text);
				lastAssistantAsks = /\?/.test(text.trim().slice(-200));
				remember("pi", text);
			}
		}
	});

	pi.on("agent_settled", async (_event, ctx) => {
		marker = lastAssistantAsks ? "🙋" : "🟢";
		applyTitle(ctx);
		process.stdout.write("\x07"); // bell → tmux window flag
		settledAt = Date.now();
		if (idleTimer) clearTimeout(idleTimer);
		idleTimer = setTimeout(() => {
			const mins = Math.max(1, Math.round((Date.now() - settledAt) / 60000));
			const dim = (s: string) => ctx.ui.theme.fg("dim", s);
			const staticRecap = [
				dim(`⏸ Recap — waiting for you (${mins}m):`),
				dim(`  you: ${lastUser || "(none)"}`),
				dim(`  pi:  ${lastAssistant || "(none)"}`),
			];
			ctx.ui.setWidget("pi-fleet-recap", staticRecap);
			const gen = recapGen;
			const prompt =
				"You are recapping a paused coding-agent conversation for its returning user. " +
				"Reply with exactly 2 terse lines, no markdown: line 1 what was just done/discussed; " +
				`line 2 what the agent is waiting on from the user.\n\nTranscript excerpt:\n${recent.join("\n")}`;
			const model = resolveRecapModel(ctx);
			const args = ["-p", "--no-session", "--no-extensions", "--no-skills", "--no-prompt-templates",
				"--no-context-files", "--no-tools"];
			if (model) args.push("--model", model);
			args.push(prompt);
			const child = execFile(
				"pi",
				args,
				{ timeout: 60000 },
				(err, stdout) => {
					if (err || stopped || gen !== recapGen) return; // user came back, session gone, or call failed
					const lines = stdout.trim().split("\n").filter(Boolean).slice(0, 3);
					if (lines.length === 0) return;
					ctx.ui.setWidget("pi-fleet-recap", [
						dim(`⏸ Recap — waiting for you (${mins}m):`),
						...lines.map((l) => dim(`  ${l.trim()}`)),
					]);
				},
			);
			child.stdin?.end();
		}, IDLE_RECAP_MS);
	});

	pi.on("session_shutdown", async () => {
		stopped = true;
		if (idleTimer) clearTimeout(idleTimer);
		for (const t of titleTimers) clearTimeout(t);
		titleTimers = [];
	});

	pi.registerCommand("ref", {
		description: "Insert a pointer to another pi session (agent can read its transcript)",
		handler: async (_args, ctx) => {
			const current = ctx.sessionManager.getSessionFile();
			const sessions = (await SessionManager.listAll())
				.filter((s) => s.path !== current)
				.sort((a, b) => b.modified.getTime() - a.modified.getTime())
				.slice(0, 15);
			if (sessions.length === 0) {
				ctx.ui.notify("No other sessions found", "warning");
				return;
			}
			const labels = sessions.map((s) => {
				const title = s.name ?? truncate(s.firstMessage, 40) ?? "(unnamed)";
				return `${title} — ${path.basename(s.cwd || "?")} (${age(s.modified)})`;
			});
			const choice = await ctx.ui.select("Refer to session:", labels);
			if (!choice) return;
			const picked = sessions[labels.indexOf(choice)];
			const title = picked.name ?? truncate(picked.firstMessage, 40);
			ctx.ui.pasteToEditor(
				`(related pi session "${title}" in ${picked.cwd} — transcript: ${picked.path} ` +
					`— a pi session .jsonl; read the relevant parts if useful) `,
			);
		},
	});
}
