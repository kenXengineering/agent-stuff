# Repository Guidelines

## Project Overview

Personal monorepo of agent tooling, one folder per deliverable:

- **OMP extensions** (`omp-plugins/`): TypeScript extensions for the [oh-my-pi](https://github.com/can1357/oh-my-pi) coding agent (`omp`).
- **Tern plugins** (`tern-plugins/`): Luau plugins for the Tern terminal (blocks, lenses, routes).
- **Agent Skills and more**: planned, none committed yet. See "Agent Skills" below.

Everything ships as **source**. There is no build step, no root `package.json`, no workspace.

> `confirm-agent-stop` (OMP) and `subagents` (Tern) live on open branches (`feat/confirm-agent-stop`, `feat/subagent-status`, PR #1) until merged. `main` has only `omp-plugins/pdf-export`.

## Architecture & Data Flow

### OMP extension (`omp-plugins/<name>/`)
- `package.json` declares `"omp": { "extensions": ["./src/index.ts"] }`, `"type": "module"`, `"private": true`. Name is `omp-<dir>`.
- `src/index.ts` **default-exports a function taking `ExtensionAPI`** (`pi`). It registers `pi.registerCommand` / `pi.on(...)` handlers. No other entry point.
- State lives in **closure variables inside that function**, not module globals.
- Types come from `@oh-my-pi/pi-coding-agent`, which is provided by the omp host and is **not** declared in `package.json`.
- `pdf-export`: `/pdf` → `select.ts` (parse args, pick exchanges from `ctx.sessionManager.getBranch()`) → `render.ts` (markdown → HTML → headless Chromium `--print-to-pdf`) → `ctx.ui.notify`.
- `confirm-agent-stop`: `session_start` installs a `CustomEditor` subclass whose `onEscape`/`onClear`/`onExit` are wrapped behind a confirm dialog.

### Tern plugin (`tern-plugins/<id>/`)
Two Luau VMs per plugin, declared in `plugin.toml`:
- **Host half** (`host.luau`, runs in the session daemon): `tern.block.define(id, { init, view, key, event, save, title })`. Blocks are panes whose state and view are Lua. Every handler has a **2 s budget**.
- **Window half** (`window.luau`, runs per Tern window): commands, binds, `tern.route.link/open`, layout. Only this half can place panes.
- **Host → window** goes through `cx:open("<private-scheme>://…")`; the window half claims the URL in `tern.route.link` and calls `cx.layout:split(...)`. Example: `tern-subagents://transcript?path=…&label=…` (producer `host.luau`, consumer `window.luau`, encoding in `lib/util.luau`).
- **Filesystem and process access**: Luau has no `stat`/seek. All reads go through `lib/util.luau` `scan()` → `tern.process.run({"sh", "scripts/scan.sh", …})`, which runs off the worker. Output is tab-separated text parsed in Luau.
- `subagents` data flow: omp's per-subagent transcripts (`~/.omp/agent/sessions/<cwd bucket>/<session>/<Agent>.jsonl`) → `scan.sh` + `agent.awk` digest only changed files → `lib/agents.luau` `classify()` → `host.luau` renders native `agent` nodes.

## Key Directories

| Path | Purpose |
| --- | --- |
| `omp-plugins/<name>/src/` | Extension source (`index.ts` entry, helpers split by concern) |
| `tern-plugins/<id>/` | `plugin.toml`, `host.luau`, `window.luau`, `lib/`, `scripts/` |
| `.worktrees/` | **Gitignored.** One git worktree per branch of work (see Workflow) |

## Development Commands

Only commands that exist and were observed. There is no build/lint/test script.

```sh
# OMP: load for a one-off run, or install by symlink
omp -e ./omp-plugins/<name>
omp plugin link ./omp-plugins/<name>

# Tern: register in place (reloads on save), inspect, force reload
tern plugin link tern-plugins/<id>
tern plugin list            # "ready" = loaded; without a daemon it only means the manifest parsed
tern plugin reload          # exit 1 on a failed plugin
tern plugin types /tmp/x    # writes tern.d.luau for luau-lsp

# Tern static check (luau-lsp is not installed by the repo; download a release binary)
luau-lsp analyze --platform=standard --definitions=@tern=/tmp/x/tern.d.luau \
  host.luau window.luau lib/*.luau
sh -n tern-plugins/<id>/scripts/scan.sh
```

Write generated `tern.d.luau` **outside** the repo: it is not gitignored.

### Git / PR workflow
- Remote `origin` = `git@github.com:kenXengineering/agent-stuff.git`, default branch `main`. Other agents work concurrently: **never edit on `main`**.
- One branch + one worktree per piece of work: `git worktree add .worktrees/<name> -b <type>/<name>`. Branches: `feat/<kebab>`, `docs/<kebab>`.
- Commit subjects: sentence-case imperative, no prefixes (`Add subagents Tern plugin: …`). PRs via `gh pr create --base main`; no templates, no CI.

## Code Conventions & Common Patterns

### TypeScript (OMP)
- Runs on **Bun** (uses `Bun.spawn`, `Bun.markdown.html`, `Bun.escapeHTML`). Keep imports Bun-compatible; no transpile step exists.
- **Errors as messages**: helpers throw `Error("/cmd: reason\n" + USAGE)`; the handler surfaces `err instanceof Error ? err.message : String(err)` via `ctx.ui.notify(..., "error")`.
- **Read omp internals defensively**: untyped objects are probed with `"key" in obj` + `typeof` and narrowing predicates, never cast (`composerState`, `BranchEntry` in `pdf-export/src/select.ts`).
- **Fail safe**: a failed confirm dialog resolves to "keep running". Wrap handlers once (`WeakSet`/`WeakMap`) and re-check state after any `await`.
- Supervise child processes: timeout, kill on success marker, `finally` cleans temp dirs.
- Comments explain *why* (a platform quirk, an omp behaviour), not what.

### Luau (Tern)
- Every file starts `--!strict`, then a header comment on the module's role. Section banners (`-----`) split `host.luau`.
- Model state as an `export type …State` with trailing field comments; mutate in handlers, return, let `view` re-render. `view` must be pure.
- **Keyed nodes**: give list items `p.key` (stable ids) so scroll and fold state survive reorders.
- **Background work** is a `tern.timer` loop guarded by `running(cx.pane)` (checked before launching, in callbacks, and before rescheduling); keep a `stopped` flag before `cx:exit`.
- **Untyped JSON**: `pcall(tern.json.decode, line)`, then `type(x) == "…"` checks. Filter by line prefix *before* decoding large lines.
- **Clocks**: `scan.sh` reports `now <epoch>`; `wall()` = scan time + `tern.now()` delta. Don't assume Luau knows wall time.
- Round-trip costs: chunk argv at 40 names; join parallel `scan` calls with a `pending` counter.
- Keep tunables as named constants (`TICK_MS`, `STALE_MS`). `STALE_MS` is also documented in the plugin README: change both.
- Helpers `with()`, `safe()`, `has()` are duplicated in `host.luau` and `lib/transcript.luau`; move shared ones to `lib/util.luau` rather than copying again.

### Shell / awk (`scripts/`)
- POSIX `sh` only; header lists every subcommand and the tools used (keep it truthful: `scan.sh` uses `sh awk grep head ls wc tail date cut tr`).
- Output is tab-separated records, `@@<TAB>name` frames per item. Read-only; never write files.
- In awk, a regex literal passed as a function argument means `$0 ~ /re/` (a 0/1). Pass strings, or use `index`/`substr`.

## Important Files

| File | Why it matters |
| --- | --- |
| `omp-plugins/pdf-export/src/index.ts` | Reference OMP extension (command + notify) |
| `omp-plugins/confirm-agent-stop/src/index.ts` | Reference for wrapping omp UI handlers |
| `omp-plugins/*/package.json` | `omp.extensions` entry |
| `tern-plugins/subagents/plugin.toml` | Reference Tern manifest (`schema = 1`, `id`, `host`, `window`, `[[blocks]]`) |
| `tern-plugins/subagents/host.luau`, `window.luau` | Block definitions; URL-claim route |
| `tern-plugins/subagents/lib/agents.luau` | Session discovery, digest parsing, status rules |
| `omp-plugins/README.md`, `tern-plugins/README.md` | Index of plugins (one line each) |
| `.gitignore` | Only `.worktrees/` |

## Runtime/Tooling Preferences

- **OMP extensions: Bun.** omp's plugin manager installs with `bun install`; no Node/npm needed. No lockfile, no `engines`.
- **Tern plugins: Luau** inside the Tern app. Needs POSIX `sh`, `awk`, `grep`, `tail`, `wc`, `date`, `cut`, `tr` on the daemon host (macOS/Linux; not Windows).
- No formatter or linter config exists (no tsconfig, Biome, ESLint, Prettier, `.editorconfig`). Match the surrounding style: **tabs**, double quotes, trailing commas as in the existing files.
- Don't introduce a root `package.json`, workspace, or new tooling unless asked.
- Docs: Tern SDK `https://docs.stencil.so/tern/index.md` (every page has an `.md` twin); omp docs are readable as `omp://<name>.md` inside omp.

## Testing & QA

- **No automated tests, CI, or coverage exist.** Do not add test scaffolding for wiring; verification is a smoke run of the changed path plus static checks.
- **OMP extension**: `omp -e ./omp-plugins/<name>`, exercise the command/key, record the omp version tested (`confirm-agent-stop/README.md` does this).
- **Tern plugin**: `tern plugin link` → `tern plugin list` shows `ready` → `luau-lsp analyze` clean → run the block against real data.
- **Isolating a Tern smoke test** (don't touch the live config):
  - Use `TERN_CONFIG_DIR=/tmp/x TERN_DAEMON_SOCKET=/tmp/x/daemon.sock`, then `tern plugin link`.
  - `tern serve` (headless) **does not load window halves**, and shows plugin blocks only after `tern ctl … remote loopback <sock>`. To test routes or splits, launch a real instance: `tern --control /tmp/x/ctl.sock <dir>`, then drive it with `tern ctl --control … palette "<name>"`, `key j`, `click X Y [cmd]`, `shot NAME`. Run it from a temp cwd, because `shot` writes `target/shots/` relative to the cwd.
- State in the PR what you ran and what you could **not** run (e.g. "not tested in the live Tern window").

## Agent Skills (planned)

Nothing committed yet. omp discovers `<skills-root>/<skill-name>/SKILL.md`, one level deep, with frontmatter `name` (defaults to the directory name) and a one-line `description` that drives matching (`omp://skills.md`). Skills bundled next to an extension package are found by the `omp-plugins` provider. *Proposal:* put them at `skills/<name>/SKILL.md` and add an index line to a `skills/README.md`.

## Adding a Plugin: Checklist

1. `git worktree add .worktrees/<name> -b feat/<name>` from `origin/main`.
2. Copy the nearest reference plugin's layout; keep to the conventions above.
3. Add a `README.md` (install, usage/keys, how it works, **Limits**) and a `- \`name\` — description` line to the folder's index README.
4. Smoke test, run the static check, then commit and open a PR (`gh pr create --base main`).
