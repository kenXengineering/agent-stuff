# Subagents (Tern plugin)

A Tern block that lists the running [omp](https://github.com/can1357/oh-my-pi) subagents and what each is doing, and opens any
one's live transcript — in the same block, or in a block below it.

| Input | In the list | In a transcript |
| --- | --- | --- |
| Click, `Enter` | Open the transcript in this block | — |
| `⌘`-click, `o` | Open the transcript in a new block **below** this one | — |
| `↑` `↓` / `j` `k` | Select | Move the cursor |
| `Esc`, or `←` `←` (within 0.7 s) | — | Back to the list |
| `Space` | — | Fold or unfold the entry under the cursor |
| `G` / `g` | — | Follow the newest entry / jump to the top |
| `p`, `r` | — | Load earlier history / reload |
| `s` | Switch to the next omp session of this directory | — |

A transcript opened below is a `subagents.transcript` block with the same keys (`Esc` does nothing there).

## Install

```sh
tern plugin link /path/to/agent-stuff/tern-plugins/subagents
```

Then open the command palette and run **New Subagents block** from the pane where omp runs (the block takes
that pane's directory). `tern plugin types tern-plugins/subagents` writes `tern.d.luau` for luau-lsp.

## How it works

The block reads omp's own session files; nothing needs to be installed on the omp side.

- omp keeps one transcript per subagent at
  `~/.omp/agent/sessions/<cwd bucket>/<session>/<AgentName>.jsonl` (`PI_CODING_AGENT_SESSION_DIR`,
  `PI_CODING_AGENT_DIR` and `PI_CONFIG_DIR` are honoured). The block picks the newest session of its directory.
- `scripts/scan.sh` + `scripts/agent.awk` (run through `tern.process.run`, off the Luau worker) report file sizes
  and digest only the changed transcripts: tool/request counts, cost, the last context size and the last few
  entries. Unchanged transcripts cost one `wc -c`.
- Status comes from the newest significant entry:

  | Last entry | Status |
  | --- | --- |
  | `tool_execution_start`, a tool result, a user message, or an assistant turn ending in `toolUse` | `running` (with the tool in flight) |
  | assistant turn ending `stop` | `idle` (finished its turn; may still be messaged) |
  | assistant turn ending `error` / `aborted` | `failed` / `aborted` |
  | `session_exit` (`normal` / `signal`) | `parked` / `aborted` |

- `⌘`-click goes host → window: a host block cannot place panes, so it opens
  `tern-subagents://transcript?path=…`; `window.luau` claims that URL in `tern.route.link` and splits the
  originating pane downward with a `subagents.transcript` block.

## Limits

- A status is inferred from files. A hard-killed omp (no `session_exit`) keeps showing `running` until the
  transcript has been silent for 45 minutes, then reads as `idle`.
- Tool calls that wait quietly (`wait`, long builds) look the same as a hung agent until they finish.
- The block follows the directory of the pane it was opened from. Two omp sessions in one directory are both
  listed in `s`; the one written last is shown first.
- Untested: `cx:open` reaches every window showing the session, so ⌘-click with two windows attached may open the transcript block twice.
- Needs a POSIX `sh` plus `awk`, `grep`, `head`, `ls`, `wc`, `tail`, `date`, `cut` and `tr` on the machine running the Tern daemon (macOS, Linux).
- Transcripts are tailed (400 lines, `p` loads 400 more) and at most the newest 160 entries are drawn.
