# IOE v3

Issue Orchestration Engine v3 for the [Pi coding agent](https://pi.dev).

A **declarative DAG** for continuous issue resolution: select → plan → implement → test → document → review → fold-in → triage → report → merge, with human-in-the-loop gates at every critical decision point. The happy path is a [pi-taskflow](https://www.npmjs.com/package/pi-taskflow) graph the runtime statically validates and enforces — no agent has to "remember" the loop.

## Why v3

The reliability bottleneck in a procedural orchestration loop is the orchestrator agent itself — a runtime interpreter of a long skill that has to remember phase ordering, state-file updates, per-worktree round budgets, and never skip a gate. v3 moves the happy path into a **declarative DAG** so the runtime enforces it:

- **Statically verified** — the taskflow runtime validates the graph (no cycles, no dangling refs, every `{steps.X}` reference declared in `dependsOn`) before spending a token.
- **Context-isolated** — worktree paths, plans, and review findings live in the runtime, not agent memory. Only the final result reaches your conversation.
- **Gates are runtime-enforced** — `approval` and `gate` phases never get silently bypassed; non-interactive runs auto-reject (fail-safe).
- **Resumable** — crash or stop mid-way, resume with `/tf resume <runId>`; completed phases with matching inputs are skipped.
- **Pure single-purpose agents** — the reviewer is read-only by tool whitelist, not by prompt; the implementer writes; the selector reads. Each phase declares its `tools`.
- **No state-file juggling** — taskflow's runId + resume replace hand-rolled state files and instance-number scanning.

## Requirements

- [pi](https://pi.dev) coding agent
- [pi-taskflow](https://www.npmjs.com/package/pi-taskflow) (flow runtime + skill)
- [@tintinweb/pi-subagents](https://www.npmjs.com/package/@tintinweb/pi-subagents) (agent discovery)

## Install

```bash
pi install git:github.com/jj-link/ioe-v3
```

The package ships a launcher script, `ioe-v3.sh`, that does all the deterministic work (arg parsing, preflight, bootstrap, config) in bash before pi starts — so the model never has to parse args or remember to bootstrap. On first run it also symlinks the agents + flows into `~/.pi/agent/`.

## Usage

```bash
./ioe-v3.sh                # interactive — pick an issue
./ioe-v3.sh --issue 42     # skip selection, work on issue 42
./ioe-v3.sh --base main    # merge into main instead of dev
./ioe-v3.sh --rebootstrap  # re-run the per-repo setup interview
./ioe-v3.sh owner/repo     # target a specific repo
```

Run it from inside your project's git repo. It launches a pi session with a `/tf run ioe-v3 ...` startup message containing clean, pre-parsed args — the model just executes it. The skill (`/skill:ioe-v3`) only engages for the blocked-run menu and iteration loop, the judgment work bash can't do.

Sequential only. To work on independent issues at the same time, spawn a second terminal running `ioe-v3.sh` — each gets its own runId and worktree.

## How it works — three layers
```
ioe-v3.sh                       bash launcher: arg parsing, preflight, bootstrap,
                                config, links agents/flows, starts pi with clean args
skills/SKILL.md                 thin outer loop: handle blocked runs, drive iterations
taskflows/ioe-v3.json           the main DAG — one iteration's happy path
taskflows/ioe-v3-tail.json      post-review tail, run only when review-gate blocks
taskflows/review-continue.json  extra review/fix rounds for the "continue" menu option
agents/*.md                     9 role agents (selector, planner, implementer, tester,
                                doc-writer, reviewer, triage, reporter, merger)
```

### The main flow (`ioe-v3`)

`cleanup → select → select-approve → plan → plan-approve → implement → test → document → review-1 → fix-1 → review-2 → fix-2 → review-3 → review-summary → review-gate → fold-in → fold-in-apply → fold-in-verify → fold-in-verify-gate → triage → triage-approve → triage-create → reports → merge-approve → merge → [conflict-approve → merge-resume] → result`

The review loop is **unrolled to 3 rounds** (flat — no difficulty-based budget) with `when` guards that cascade-skip once a round comes back clean. The reviewer and fixer are separate agents; the DAG is the loop controller — no agent has to "remember" to iterate.

### When review blocks

If `review-gate` BLOCKs (3 rounds didn't clear the blockers), the run halts and the outer skill presents the rich menu — `continue` / `fix` / `override` / `reclassify` / `drop` — then chains the `review-continue` and `ioe-v3-tail` sub-flows. The main flow can't be resumed past a blocked gate (the cached summary still reports blockers), so the tail runs fresh with the latest summary passed as args. This keeps the happy path as one run = one iteration while still handling the rare convergence failure.

## Decisions (vs a procedural loop)

- No time/budget limits — resume + runId make long runs safe.
- No parallel mode — spawn a second instance instead. `select` emits a 1-element array; `map` threads it.
- Flat 3-round review cap — no difficulty-based budget arithmetic.
- Reviewer and fixer are separate agents; the DAG controls the loop.
- `ioe-triage` consolidates review findings → creates GitHub issues.
- Bootstrap is conversational in the outer skill, cached to `.claude/ioe-v3.local.md`, with a one-line confirmation on reuse.

See [`skills/SKILL.md`](./skills/SKILL.md) for the full outer-loop contract and [`taskflows/`](./taskflows/) for the DAGs.
