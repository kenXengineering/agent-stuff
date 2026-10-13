// Confirm before a keypress stops or kills running agent work.
//
//   Esc            while a turn is running   -> "Stop the running agent?"
//   Ctrl+C twice   while work is running     -> "Quit omp?"  (omp's double Ctrl+C exits)
//   Ctrl+D         while work is running     -> "Quit omp?"
//
// Idle behavior is untouched. The dialog defaults to "Keep running", Esc inside it
// means keep, and Esc pressed again right after a dismissal is swallowed, so mashing
// Esc can never stop the agent.
//
// How: omp has no "before abort" event, so the extension installs a CustomEditor whose
// `onEscape` / `onClear` / `onExit` handlers are wrapped. omp's composer only calls
// them when it holds focus, so dialogs, the Agent Hub and other overlays keep their
// own Esc behavior. Not covered: Agent Hub `x` (kill) and `/jobs kill`, which never
// pass through the composer.

import type { ExtensionAPI, ExtensionContext } from "@oh-my-pi/pi-coding-agent";
import { CustomEditor } from "@oh-my-pi/pi-coding-agent";

type Handler = () => void;
type Guarded = "onEscape" | "onClear" | "onExit";

/** omp's own window for "second Ctrl+C exits". */
const DOUBLE_CTRL_C_MS = 500;
/** After a dialog is dismissed with "keep", swallow Esc for this long. */
const COOLDOWN_MS = 400;

const KEEP = "Keep running";

/** The subset of `editor.composerState()` this extension reads. */
interface ComposerState {
	/** A turn is streaming or the working spinner is up. */
	running: boolean;
	/** True while the composer is viewing a focused subagent; Esc there only returns to the main session. */
	viewing: boolean;
}

/** omp assigns `composerState` on the editor after construction; read it defensively. */
function composerState(editor: object): ComposerState {
	const state: ComposerState = { running: false, viewing: false };
	if (!("composerState" in editor) || typeof editor.composerState !== "function") return state;
	const raw: unknown = editor.composerState();
	if (raw && typeof raw === "object") {
		if ("running" in raw) state.running = raw.running === true;
		if ("viewing" in raw) state.viewing = Array.isArray(raw.viewing) && raw.viewing.length > 0;
	}
	return state;
}

export default function confirmAgentStop(pi: ExtensionAPI) {
	let ctx: ExtensionContext | undefined;
	let installed = false;
	let asking = false;
	let cooldownUntil = 0;
	let lastClear = 0;
	// Once the user confirmed a quit, never intercept again: a hung shutdown must stay force-quittable.
	let quitConfirmed = false;

	const runningJobs = (live: ExtensionContext): number => live.getAsyncJobSnapshot()?.running.length ?? 0;

	/** Is the main agent mid-turn? */
	const turnRunning = (live: ExtensionContext, editor: object): boolean =>
		composerState(editor).running || !live.isIdle();

	/** Would a bare Esc interrupt the main agent right now? */
	const escapeStops = (live: ExtensionContext, editor: object): boolean =>
		!composerState(editor).viewing && turnRunning(live, editor); // focused subagent: Esc only unfocuses

	/** Would exiting omp kill running work? */
	const exitKills = (live: ExtensionContext, editor: object): boolean =>
		turnRunning(live, editor) || runningJobs(live) > 0;

	const describeWork = (live: ExtensionContext, editor: object): string => {
		const parts: string[] = [];
		if (turnRunning(live, editor)) parts.push("an agent turn");
		const jobs = runningJobs(live);
		if (jobs > 0) parts.push(`${jobs} background job${jobs === 1 ? "" : "s"} / subagent${jobs === 1 ? "" : "s"}`);
		return parts.join(" and ");
	};

	/** Resolves true only when the user explicitly picks the destructive option. */
	const confirm = async (live: ExtensionContext, title: string, body: string, stopLabel: string): Promise<boolean> => {
		asking = true;
		let stop = false;
		try {
			const choice = await live.ui.select(`${title}\n${body}`, [KEEP, stopLabel], { initialIndex: 0 });
			stop = choice === stopLabel;
		} catch {
			stop = false; // fail safe: a broken dialog never stops anything
		} finally {
			asking = false;
			if (!stop) cooldownUntil = Date.now() + COOLDOWN_MS;
		}
		return stop;
	};

	const blocked = (): boolean => asking || Date.now() < cooldownUntil;

	/** Ask before quitting; on "Quit omp" disarm the guard for good and run `quit`. */
	const confirmQuit = (live: ExtensionContext, editor: object, quit: () => void): void => {
		if (blocked()) return;
		void confirm(live, "Quit omp?", `${describeWork(live, editor)} still running; quitting stops it.`, "Quit omp").then(stop => {
			if (!stop) return;
			quitConfirmed = true;
			quit();
		});
	};

	class GuardedEditor extends CustomEditor {
		constructor(...args: ConstructorParameters<typeof CustomEditor>) {
			super(...args);
			const wrapped = new WeakMap<Handler, Handler>();
			const wrappedValues = new WeakSet<Handler>();

			const make = (name: Guarded, original: Handler): Handler => {
				switch (name) {
					case "onEscape":
						return () => {
							const live = ctx;
							if (!live || !escapeStops(live, this)) return original();
							if (blocked()) return;
							void confirm(live, "Stop the running agent?", "Esc interrupts the current agent turn.", "Stop agent").then(stop => {
								// The run may have finished while the dialog was open; forwarding then
								// would trigger idle-Esc actions (rewind / tree) instead.
								if (stop && escapeStops(live, this)) original();
							});
						};
					case "onClear":
						// omp exits on a second Ctrl+C within DOUBLE_CTRL_C_MS; the first only clears the draft.
						return () => {
							const now = Date.now();
							const second = now - lastClear < DOUBLE_CTRL_C_MS;
							const live = ctx;
							if (quitConfirmed || !live || !second || !exitKills(live, this)) {
								lastClear = now;
								return original();
							}
							lastClear = 0;
							// The confirm outlasts omp's own 500 ms window, so exit explicitly.
							confirmQuit(live, this, () => live.shutdown());
						};
					case "onExit":
						return () => {
							const live = ctx;
							if (quitConfirmed || !live || !exitKills(live, this)) return original();
							confirmQuit(live, this, original);
						};
				}
			};

			for (const name of ["onEscape", "onClear", "onExit"] as const) {
				const wrap = (fn: Handler): Handler => {
					if (wrappedValues.has(fn)) return fn;
					let w = wrapped.get(fn);
					if (!w) {
						w = make(name, fn);
						wrapped.set(fn, w);
						wrappedValues.add(w);
					}
					return w;
				};
				// CustomEditor declares these as class fields (own data properties), so
				// intercept assignment on the instance. omp assigns them after construction,
				// and temporarily swaps `onEscape` for modal work; every swap is wrapped too,
				// guarded by the same "is something running" check.
				let current = this[name];
				Object.defineProperty(this, name, {
					configurable: true,
					enumerable: true,
					get: () => current,
					set: (fn: Handler | undefined) => {
						current = typeof fn === "function" ? wrap(fn) : fn;
					},
				});
				if (current) current = wrap(current);
			}
		}
	}

	pi.on("session_start", async (_event, eventCtx) => {
		if (eventCtx.mode !== "tui" || !eventCtx.hasUI || eventCtx.agent?.kind !== "main") return;
		ctx = eventCtx;
		if (installed) return;
		installed = true;
		eventCtx.ui.setEditorComponent((tui, theme, keybindings) => new GuardedEditor(tui, theme, keybindings));
	});

	pi.on("session_shutdown", async () => {
		ctx = undefined;
		installed = false;
	});
}
