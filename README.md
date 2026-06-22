# IOE v3

Issue Orchestration Engine v3 for the [Pi coding agent](https://pi.dev).

A declarative DAG for continuous issue resolution: plan → implement → test → review → merge, with human-in-the-loop gates at every critical decision point.

## Requirements

- [pi](https://pi.dev) coding agent
- [pi-taskflow](https://www.npmjs.com/package/pi-taskflow) extension + skill
- [pi-subagents](https://www.npmjs.com/package/pi-subagents) or compatible subagent extension

## Install

```bash
pi install git:github.com/your-name/ioe-v3
```

## Usage

```
/skill:ioe-v3            # interactive mode — pick issues, approve plans, review
/skill:ioe-v3 --issue 42 # skip selection, work on issue 42
/skill:ioe-v3 --parallel # parallel mode for independent issues
```

## How It Works

Replaces the procedural SKILL.md of IOE v2 with a [pi-taskflow](https://www.npmjs.com/package/pi-taskflow) DAG:

- **Statically verified** — the runtime validates the graph (no cycles, no dangling refs) before spending tokens
- **Context-isolated** — intermediate results stay in the runtime, only final output reaches your conversation
- **Resumable** — crash or stop mid-way, resume with `/tf resume <runId>`
- **Reusable** — saved as `/tf:ioe-v3`, run it any time with arguments

See [`skills/SKILL.md`](./skills/SKILL.md) for phase details.
