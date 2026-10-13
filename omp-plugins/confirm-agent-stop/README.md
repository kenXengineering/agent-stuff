# omp-confirm-agent-stop

Asks before a keypress stops or kills running agent work in the omp TUI.

| Key (while work is running) | Prompt | If you pick "Keep running" / dismiss |
|---|---|---|
| `Esc` | Stop the running agent? | agent keeps going |
| `Ctrl+C` twice (omp's exit gesture) | Quit omp? | omp keeps running; next `Ctrl+C` is a plain "clear draft" again |
| `Ctrl+D` | Quit omp? | omp keeps running |

Idle behavior is untouched (double-Esc rewind, Ctrl+C clears the draft, Ctrl+D exits).

"Running work" is a streaming turn, or for the quit prompts also background jobs / detached subagents (`getAsyncJobSnapshot`).

## Built so mashing Esc is safe

- The dialog defaults to **Keep running**; `Enter` keeps, `Esc` keeps.
- After a dismissal, Esc is swallowed for 400 ms, so a held or mashed Esc cannot re-open and then confirm anything.
- Only an explicit "Stop agent" / "Quit omp" selection stops anything. A dialog error also keeps the agent running.
- When a subagent is focused, Esc only returns to the main session in omp, so no prompt is shown.
- After you confirm a quit the guard disarms, so a hung shutdown can still be force-quit with `Ctrl+C`.

## Install

```sh
omp plugin link ./confirm-agent-stop
```

One-off: `omp -e ./confirm-agent-stop`.

If you already have `~/.omp/agent/extensions/confirm-escape-interrupt.ts`, remove it. Both extensions call `setEditorComponent`, so only the last one loaded would be active. That older version also prompts when Esc is used to return from a focused subagent.

## Limits

omp has no "before abort" event, so this wraps the composer's `onEscape` / `onClear` / `onExit` handlers (`CustomEditor`). It relies on `editor.composerState()` (`running`, `viewing`), which is not documented API; if omp renames it the guard falls back to `ctx.isIdle()` and stops recognising the focused-subagent case.

Not covered, because these never pass through the composer:

- **Agent Hub `x`** (kill a subagent) and **`/jobs kill`**. They act immediately.
- Esc while a user `!bash` / eval command (not an agent) is running.

## Tern

Tern cannot guard Esc: keys reach the program as raw pty input, and a plugin key bind on `escape` would capture it in every pane (vim included). Closing a block, tab, session or window that has an agent mid-turn, and quitting Tern, are already confirmed by Tern itself (`confirm_close`, default `running_programs`; never set it to `never`). So there is no Tern plugin here.

Tested in a plain terminal against omp 18.10.3. Not tested inside a Tern pane; the prompt is an ordinary omp selector, so it should render there too.
