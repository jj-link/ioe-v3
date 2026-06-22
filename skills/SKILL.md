---
name: ioe-v3
description: Issue Orchestration Engine v3 — declarative DAG for continuous issue resolution via pi-taskflow. Use when you want to work through GitHub issues in a session with planning, implementation, testing, adversarial review, and merge automation.
---

# IOE v3

Declarative issue orchestration as a pi-taskflow DAG. Replaces the procedural SKILL.md approach of IOE v2 with a statically verified graph of phases.

## Install

```bash
# From git repo
pi install git:github.com/your-name/ioe-v3

# Or from local
cd /home/workbench/ioe-v3 && npm install  # if needed
```

## Usage

Invoke in a Pi session:

```
/skill:ioe-v3
```

Or with arguments:

```
/skill:ioe-v3 --issue 42
/skill:ioe-v3 --parallel
/skill:ioe-v3 --base main
```

## Flow

The full DAG definition lives in `taskflows/ioe-v3.json`. Run it via the taskflow tool with `name: "ioe-v3"`.

## Phases

| # | Phase | Type | Description |
|---|-------|------|-------------|
| 0 | cleanup | agent | Remove stale worktrees and orphaned branches |
| 1 | select | agent | Recommend issues to work on (skipped if `--issue` set) |
| 1a | select-approve | approval | Human picks which issues to tackle |
| 2 | plan | map | Create worktrees, run baseline tests, produce plans per issue |
| 2a | plan-approve | approval | Human approves/rejects/adjusts plans |
| 3 | implement | map | Implement changes per approved plan |
| 4 | test | map | Run existing tests + write new tests |
| 5 | document | reduce | Update docs across all worktrees |
| 6 | review | map | Adversarial review per worktree |
| 6a | review-gate | gate | Halt on unresolved merge blockers |
| 7 | triage | agent + approval | Consolidate findings, human approves triage issues |
| 8 | reports | map | Generate HTML reports |
| 9 | merge-approve | approval | Human approves merge strategy |
| 10 | merge | map | Commit, rebase, merge, cleanup |
