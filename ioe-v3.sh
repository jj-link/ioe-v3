#!/usr/bin/env bash
#
# ioe-v3.sh — deterministic launcher for the IOE v3 issue orchestration engine.
#
# Does all the deterministic work in bash (arg parsing, preflight, bootstrap
# detection, config writing) so the model inside pi never has to. Then launches
# a pi session with a startup message that directly runs the taskflow with clean
# args — no model arg-parsing, no skippable bootstrap prose.
#
# Usage:
#   ./ioe-v3.sh                          # interactive — pick an issue
#   ./ioe-v3.sh --issue 42               # work on issue 42
#   ./ioe-v3.sh --base main              # merge into main instead of dev
#   ./ioe-v3.sh --rebootstrap            # re-run the per-repo setup interview
#   ./ioe-v3.sh owner/repo               # target a specific repo
#   ./ioe-v3.sh --issue 42 --base main   # combine flags
#
# The pi session that opens will run the ioe-v3 taskflow directly. The skill
# (skills/SKILL.md) only engages for the blocked-run menu and iteration loop —
# the judgment work bash can't do.

set -euo pipefail

# --- defaults
ISSUE=""
BASE=""
REBOOTSTRAP=false
REPO=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOE_EDITOR="nano"; command -v nano >/dev/null 2>&1 || IOE_EDITOR="vi"

# --- arg parsing (real parsing, not the model)
while [[ $# -gt 0 ]]; do
  case "$1" in
    --issue)
      ISSUE="$2"; shift 2 ;;
    --issue=*)
      ISSUE="${1#--issue=}"; shift ;;
    --base)
      BASE="$2"; shift 2 ;;
    --base=*)
      BASE="${1#--base=}"; shift ;;
    --rebootstrap)
      REBOOTSTRAP=true; shift ;;
    -h|--help)
      sed -n '2,20p' "$0"; exit 0 ;;
    -*)
      echo "ioe-v3: unknown flag: $1" >&2; exit 2 ;;
    *)
      # positional = owner/repo
      if [[ -z "$REPO" ]]; then REPO="$1"; else
        echo "ioe-v3: unexpected extra argument: $1" >&2; exit 2
      fi
      shift ;;
  esac
done

# --- must be in a git repo
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "ioe-v3: not inside a git repository. cd into your project first." >&2
  exit 1
fi
REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

# --- gh authed?
if ! command -v gh >/dev/null 2>&1; then
  echo "ioe-v3: gh CLI not found. Install it and run 'gh auth login'." >&2
  exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
  echo "ioe-v3: gh not authenticated. Run 'gh auth login' first." >&2
  exit 1
fi

# --- resolve repo (positional, else current repo)
if [[ -z "$REPO" ]]; then
  REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
fi
if [[ -z "$REPO" ]]; then
  echo "ioe-v3: couldn't determine the GitHub repo. Pass owner/repo explicitly." >&2
  exit 1
fi

# --- base branch: default dev, verify it exists
if [[ -z "$BASE" ]]; then BASE="dev"; fi
if ! git rev-parse --verify "$BASE" >/dev/null 2>&1; then
  echo "ioe-v3: base branch '$BASE' does not exist. Available branches:" >&2
  git branch --format='  %(refname:short)' >&2
  exit 1
fi

# --- ensure .claude/ exists and is gitignored
mkdir -p "$REPO_ROOT/.claude/worktrees"
GITIGNORE="$REPO_ROOT/.gitignore"
if [[ -f "$GITIGNORE" ]]; then
  if ! grep -qx '.claude/' "$GITIGNORE" 2>/dev/null; then
    echo ".claude/" >> "$GITIGNORE"
    echo "ioe-v3: added '.claude/' to .gitignore"
  fi
else
  echo ".claude/" > "$GITIGNORE"
  echo "ioe-v3: created .gitignore with '.claude/'"
fi

# --- ensure agents + flows are linked into ~/.pi/agent/ (idempotent)
link_resources() {
  local dest_dir="$1" src_dir="$2" ext="$3"
  mkdir -p "$dest_dir"
  shopt -s nullglob
  for f in "$src_dir"/*."$ext"; do
    local name; name="$(basename "$f")"
    if [[ ! -e "$dest_dir/$name" || -L "$dest_dir/$name" ]]; then
      ln -sf "$f" "$dest_dir/$name"
    fi
  done
}
link_resources "$HOME/.pi/agent/agents" "$SCRIPT_DIR/agents" "md"
link_resources "$HOME/.pi/agent/taskflows" "$SCRIPT_DIR/taskflows" "json"

# --- bootstrap / config (.claude/ioe-v3.local.md)
CONFIG="$REPO_ROOT/.claude/ioe-v3.local.md"

detect_test_command() {
  # Scan for common test setups. Echoes "<framework>\t<command>" or empty.
  # Order matters: most-specific first.
  if [[ -f package.json ]]; then
    if grep -q '"test"' package.json 2>/dev/null; then
      # If the test script is real (not just "echo no test"), suggest npm test
      local script; script="$(python3 -c "import json,sys; s=json.load(open('package.json')).get('scripts',{}).get('test',''); print(s)" 2>/dev/null || echo "")"
      if [[ -n "$script" && "$script" != *"no test"* && "$script" != *"Error"* ]]; then
        echo -e "npm\tnpm test"; return
      fi
    fi
    if grep -q '"vitest'" package.json 2>/dev/null || compgen -G "vitest.config.*" >/dev/null 2>&1; then
      echo -e "vitest\tnpx vitest run"; return
    fi
    if grep -q '"jest'" package.json 2>/dev/null || compgen -G "jest.config.*" >/dev/null 2>&1; then
      echo -e "jest\tnpx jest"; return
    fi
    if grep -q '"mocha'" package.json 2>/dev/null || compgen -G ".mocharc.*" >/dev/null 2>&1; then
      echo -e "mocha\tnpx mocha"; return
    fi
  fi
  if [[ -f pytest.ini ]] \
     || { [[ -f pyproject.toml ]] && grep -q '\[tool.pytest' pyproject.toml 2>/dev/null; } \
     || { [[ -f setup.cfg ]] && grep -q '\[tool:pytest' setup.cfg 2>/dev/null; }; then
    echo -e "pytest\tpytest -x"; return
  fi
  if compgen -G "vitest.config.*" >/dev/null 2>&1; then echo -e "vitest\tnpx vitest run"; return; fi
  if compgen -G "jest.config.*"   >/dev/null 2>&1; then echo -e "jest\tnpx jest";       return; fi
  if compgen -G ".mocharc.*"      >/dev/null 2>&1; then echo -e "mocha\tnpx mocha";     return; fi
  if [[ -f Cargo.toml ]];    then echo -e "cargo\tcargo test";     return; fi
  if [[ -f go.mod ]];        then echo -e "go\tgo test ./...";    return; fi
  if [[ -f platformio.ini ]]; then echo -e "platformio\tpio test -e native"; return; fi
  if [[ -f Makefile ]] && grep -qE '^[[:space:]]*test:' Makefile 2>/dev/null; then
    echo -e "make\tmake test"; return
  fi
  echo ""
}

detect_test_via_agent() {
  # Agent scan over code + docs to infer the test command. $1 is the bash
  # heuristic hint ("framework\tcommand" or empty). Echoes just the command
  # string, or empty if nothing can be determined. Consults both code and
  # documentation; falls back to docs-only when there is no code.
  local hint_cmd="${1#*$'\t'}"
  local out
  out="$(run_agent "You are a test-setup scout. Determine the single command that runs this project's test suite, by consulting BOTH the code and the documentation.

CODE signals: config files (package.json scripts.test, pytest.ini, pyproject.toml [tool.pytest], setup.cfg, Cargo.toml, go.mod, platformio.ini, Makefile test target), test directories (tests/, test/, __tests__), and source that reveals the framework.
DOCUMENTATION signals: README, CONTRIBUTING, docs/, and CI config (.github/workflows) — look for 'run tests', 'to test', a Testing section. Docs often give the exact intended command (e.g. 'python -m pytest tests/ -v' rather than just 'pytest -x'). When docs and config disagree on the command form, prefer what the docs specify — that is the project's intended convention.
If there is no code (no source, no config files), rely on documentation only. If neither code nor docs reveal a test setup, output nothing.

Bash heuristic hint (verify against docs; do not trust blindly): ${hint_cmd:-none}

Output ONLY the test command on one line (e.g. 'python -m pytest tests/ -v', 'npm test', 'cargo test'). No framework label, no preamble, no quotes. If no test setup exists, output nothing." "Infer the test command for $(pwd) from code and docs." 2>/dev/null)"
  out="$(echo "$out" | grep -vE '^\s*$' | tail -1 | sed 's/^["'\'']//;s/["'\'']$//')"
  echo "$out"
}

write_config() {
  # args: test_framework test_command design_principles docs_inventory report_path base repo
  cat > "$CONFIG" <<EOF
---
test_framework: $1
test_command: $2
design_principles: $3
docs_inventory: $4
report_path: $5
base: $6
repo: $7
---
EOF
}

# run_agent <system-prompt> <task> — one-off non-interactive pi subprocess.
# Used for deterministic setup work (codebase scans, framework installs) that
# needs an agent's read/write/bash but no conversation. Echoes the agent's output.
run_agent() {
  local sp="$1"; local task="$2"
  pi -p --no-session --tools read,edit,write,bash,grep,find,ls \
    --append-system-prompt "$sp" "$task" 2>/dev/null || true
}

# generate_docs_inventory — scan the repo for doc files, show the list, let the
# user approve/edit, write .claude/docs-inventory.md. Sets DI=true on success.
generate_docs_inventory() {
  echo "    Scanning repo for documentation files (may take a minute)..."
  run_agent "You are a docs-inventory scout. Find files that are actual documentation — meant to be read by humans to understand or operate the project.\n\nINCLUDE: README files, CHANGELOG, CONTRIBUTING, LICENSE, AUTHORS, files under a docs/ directory, config files with inline comments explaining their own keys (e.g. config.ini, dashboard.service), and dependency manifests (requirements.txt, package.json).\n\nEXCLUDE (never list these): source code, tests, data files (json/yaml/csv datasets), build artifacts, and anything under local/tooling directories — .git, .claude, .pi, .opencode, .codex, .agents, node_modules, venv, __pycache__, .pytest_cache, .mypy_cache, dist, build. Internal state files and session logs are not documentation.\n\nIf a docs/ directory is empty or contains only non-doc files, say so in one line — do not list empty subdirectories individually.\n\nOutput a concise list of paths (relative to repo root) with a one-line description each. No preamble, no file writes. Format: '- <path> — <description>'. If nothing qualifies beyond the README, output just that." "Scan $(pwd) and list documentation files." > "$REPO_ROOT/.claude/.docs-scan.md"
  echo "    Found documentation files:"
  sed 's/^/      /' "$REPO_ROOT/.claude/.docs-scan.md"
  echo ""
  read -r -p "    Generate docs-inventory.md from this list? [Y] = generate  ·  [e] = edit list first  ·  [n] = skip " ans
  if [[ "${ans:-}" =~ ^[Nn] ]]; then
    rm -f "$REPO_ROOT/.claude/.docs-scan.md"
    echo "    Skipped."
    return
  fi
  if [[ "${ans:-}" =~ ^[Ee] ]]; then
    "$IOE_EDITOR" "$REPO_ROOT/.claude/.docs-scan.md" </dev/tty >/dev/tty 2>&1 || true
  fi
  run_agent "You are a docs-inventory author. Using the file list below, write a practical .claude/docs-inventory.md with two sections: (1) 'Core files' — each path with a one-line description of what it covers; (2) 'Conventions' — the documentation style actually used in this repo (markdown vs docstrings vs inline config comments), the expected level of detail, and what should always be documented when new features are added. Infer the conventions from the files listed, not from source code. Keep it concise. Write the file directly; output ONLY 'done'.

Found files:
$(cat "$REPO_ROOT/.claude/.docs-scan.md")" "Write .claude/docs-inventory.md in $(pwd)." >/dev/null
  rm -f "$REPO_ROOT/.claude/.docs-scan.md"
  echo "    Generated $REPO_ROOT/.claude/docs-inventory.md."
  read -r -p "    Review/edit it now? [y/N] " ans2
  [[ "${ans2:-}" =~ ^[Yy] ]] && "$IOE_EDITOR" "$REPO_ROOT/.claude/docs-inventory.md" </dev/tty >/dev/tty 2>&1 || true
}

if [[ "$REBOOTSTRAP" == true || ! -f "$CONFIG" ]]; then
  echo ""
  echo "=== IOE v3 bootstrap ($REPO) ==="
  echo ""

  # design principles — detect existing, or scan+draft+suggest, let user adjust
  DP="false"
  PRINCIPLES_FILE="$REPO_ROOT/.claude/design-principles.md"
  echo "  Design principles:"
  if [[ -f "$PRINCIPLES_FILE" ]]; then
    echo "    Found: $PRINCIPLES_FILE"
    echo "    [Enter] = use as-is  ·  [e] = edit  ·  [r] = regenerate from codebase scan  ·  [k] = skip"
    read -r -p "    > " ans
    case "${ans:-}" in
      ""|y|Y) DP="true"; echo "    Using existing principles." ;;
      e|E)
        "$IOE_EDITOR" "$PRINCIPLES_FILE" </dev/tty >/dev/tty 2>&1 || true
        DP="true"; echo "    Edited."
        ;;
      r|R)
        echo "    Regenerating from codebase scan (may take a minute)..."
        run_agent "You are a codebase-pattern scout. Scan the repo for: test framework + test dir structure, file/folder organization, naming conventions, error-handling patterns, existing documentation, architecture patterns. Output a concise bullet list of inferred patterns ONLY (no preamble, no file writes)." "Scan $(pwd) and report inferred codebase patterns." > "$REPO_ROOT/.claude/.scan-results.md"
        echo "    Inferred patterns:"
        sed 's/^/      /' "$REPO_ROOT/.claude/.scan-results.md"
        echo ""
        read -r -p "    Generate a design-principles.md from these patterns + standard questions (testing philosophy, architecture, error handling, docs)? [Y/n] " ans2
        if [[ ! "${ans2:-}" =~ ^[Nn] ]]; then
          run_agent "You are a design-principles author. Using the codebase scan results below, write a practical .claude/design-principles.md that captures the repo's existing patterns AND adds guidance on: testing philosophy (unit vs integration vs E2E balance), architecture patterns to enforce, error-handling approach, and what must always be documented. Keep it concise and opinionated. Write the file directly; output ONLY 'done'.

Scan results:
$(cat "$REPO_ROOT/.claude/.scan-results.md")" "Write .claude/design-principles.md in $(pwd)." >/dev/null
          rm -f "$REPO_ROOT/.claude/.scan-results.md"
          DP="true"; echo "    Generated $PRINCIPLES_FILE."
          read -r -p "    Review/edit it now? [y/N] " ans3
          [[ "${ans3:-}" =~ ^[Yy] ]] && "$IOE_EDITOR" "$PRINCIPLES_FILE" </dev/tty >/dev/tty 2>&1 || true
        else
          rm -f "$REPO_ROOT/.claude/.scan-results.md"
          echo "    Skipped generation."
        fi
        ;;
      k|K) DP="false"; echo "    Skipped (existing file left in place)." ;;
      *) DP="true" ;;
    esac
  else
    echo "    No design-principles file found."
    echo "    [Enter] = skip  ·  [g] = generate from codebase scan  ·  [m] = write manually"
    read -r -p "    > " ans
    case "${ans:-}" in
      g|G)
        echo "    Scanning codebase for patterns (may take a minute)..."
        run_agent "You are a codebase-pattern scout. Scan the repo for: test framework + test dir structure, file/folder organization, naming conventions, error-handling patterns, existing documentation, architecture patterns. Output a concise bullet list of inferred patterns ONLY (no preamble, no file writes)." "Scan $(pwd) and report inferred codebase patterns." > "$REPO_ROOT/.claude/.scan-results.md"
        echo "    Inferred patterns:"
        sed 's/^/      /' "$REPO_ROOT/.claude/.scan-results.md"
        echo ""
        run_agent "You are a design-principles author. Using the codebase scan results below, write a practical .claude/design-principles.md that captures the repo's existing patterns AND adds guidance on: testing philosophy (unit vs integration vs E2E balance), architecture patterns to enforce, error-handling approach, and what must always be documented. Keep it concise and opinionated. Write the file directly; output ONLY 'done'.

Scan results:
$(cat "$REPO_ROOT/.claude/.scan-results.md")" "Write .claude/design-principles.md in $(pwd)." >/dev/null
        rm -f "$REPO_ROOT/.claude/.scan-results.md"
        DP="true"; echo "    Generated $PRINCIPLES_FILE."
        read -r -p "    Review/edit it now? [y/N] " ans3
        [[ "${ans3:-}" =~ ^[Yy] ]] && "$IOE_EDITOR" "$PRINCIPLES_FILE" </dev/tty >/dev/tty 2>&1 || true
        ;;
      m|M)
        "$IOE_EDITOR" "$PRINCIPLES_FILE" </dev/tty >/dev/tty 2>&1 || true
        [[ -f "$PRINCIPLES_FILE" ]] && DP="true" || echo "    No file written — skipped."
        ;;
      *) echo "    Skipped." ;;
    esac
  fi

  # docs inventory — detect existing, or scan+suggest, let user adjust
  DI="false"
  DOCS_FILE="$REPO_ROOT/.claude/docs-inventory.md"
  echo "  Docs inventory:"
  if [[ -f "$DOCS_FILE" ]]; then
    echo "    Found: $DOCS_FILE"
    echo "    [Enter] = use as-is  ·  [e] = edit  ·  [r] = regenerate from scan  ·  [k] = skip"
    read -r -p "    > " ans
    case "${ans:-}" in
      ""|y|Y) DI="true"; echo "    Using existing inventory." ;;
      e|E) "$IOE_EDITOR" "$DOCS_FILE" </dev/tty >/dev/tty 2>&1 || true; DI="true" ;;
      r|R) generate_docs_inventory; DI="true" ;;
      k|K) DI="false"; echo "    Skipped (existing left in place)." ;;
      *) DI="true" ;;
    esac
  else
    echo "    No docs-inventory file found."
    echo "    [Enter] = skip (docs agent auto-scans at runtime)  ·  [g] = generate from scan"
    read -r -p "    > " ans
    case "${ans:-}" in
      g|G) generate_docs_inventory; DI="true" ;;
      *) echo "    Skipped — docs agent will auto-scan at runtime." ;;
    esac
  fi

  # test framework — agent scan over code + docs (bash heuristic as hint + fallback)
  HINT="$(detect_test_command)"
  echo "    Scanning code + docs for the test command (may take a minute)..."
  DETECTED_CMD="$(detect_test_via_agent "$HINT")"
  [[ -z "$DETECTED_CMD" ]] && DETECTED_CMD="${HINT#*$'\t'}"
  DETECTED_FW=""
  [[ -n "$DETECTED_CMD" ]] && DETECTED_FW="$(echo "$DETECTED_CMD" | awk '{print $1}')"

  echo "  Testing setup:"
  if [[ -n "$DETECTED_CMD" ]]; then
    echo "    Detected: $DETECTED_FW  (suggested command: '$DETECTED_CMD')"
    echo "    [Enter] = use this  ·  [c] = change command  ·  [s] = set up a new framework  ·  [k] = skip testing"
    read -r -p "  > " ans
    case "${ans:-}" in
      ""|y|Y) TEST_CMD="$DETECTED_CMD"; TEST_FW="$DETECTED_FW" ;;
      c|C)
        read -r -p "    Enter the test command to use: " TEST_CMD
        TEST_FW="$(echo "$TEST_CMD" | awk '{print $1}')"
        ;;
      s|S)
        echo "    Which framework should I set up? Common options:"
        echo "      vitest (Node/TS), jest (Node/JS), pytest (Python), cargo test (Rust), go test (Go)"
        read -r -p "    Framework name: " SETUP_FW
        # Hand off to an ioe-selector agent to install + configure. It runs as a
        # one-off pi subprocess (non-interactive) that does the install and emits
        # the resulting test command. The agent is read+write capable.
        echo "    Setting up $SETUP_FW via a setup agent (this may take a minute)..."
        SETUP_OUT="$(run_agent "You are a test-framework setup agent. Install and configure $SETUP_FW in the current repo so that a single command runs the test suite. Create a minimal passing sanity test if none exists. Output ONLY the test command to run (e.g. 'npm test' or 'pytest -x'), nothing else." "Set up $SETUP_FW in $(pwd) and report the test command.")"
        # Take the last non-empty line as the command
        TEST_CMD="$(echo "$SETUP_OUT" | grep -vE '^\s*$' | tail -1 | sed 's/^["'\'']//;s/["'\'']$//')"
        if [[ -z "$TEST_CMD" ]]; then
          echo "    Setup agent didn't return a clear command. Falling back to manual entry."
          read -r -p "    Enter the test command (or leave blank to skip): " TEST_CMD
        else
          echo "    Done. Test command: '$TEST_CMD'"
        fi
        TEST_FW="$(echo "$TEST_CMD" | awk '{print $1}')"
        ;;
      k|K) TEST_CMD=""; TEST_FW="skipped"; echo "    Testing skipped." ;;
      *)
        # Treat typed input as a custom command
        TEST_CMD="$ans"; TEST_FW="$(echo "$TEST_CMD" | awk '{print $1}')"
        ;;
    esac
  else
    echo "    No test setup detected in this repo."
    echo "    [Enter] = skip  ·  [s] = set up a framework  ·  or type a command directly"
    read -r -p "  > " ans
    case "${ans:-}" in
      ""|k|K) TEST_CMD=""; TEST_FW="skipped"; echo "    Testing skipped." ;;
      s|S)
        echo "    Which framework should I set up? Common options:"
        echo "      vitest (Node/TS), jest (Node/JS), pytest (Python), cargo test (Rust), go test (Go)"
        read -r -p "    Framework name: " SETUP_FW
        echo "    Setting up $SETUP_FW via a setup agent (this may take a minute)..."
        SETUP_OUT="$(run_agent "You are a test-framework setup agent. Install and configure $SETUP_FW in the current repo so that a single command runs the test suite. Create a minimal passing sanity test if none exists. Output ONLY the test command to run (e.g. 'npm test' or 'pytest -x'), nothing else." "Set up $SETUP_FW in $(pwd) and report the test command.")"
        TEST_CMD="$(echo "$SETUP_OUT" | grep -vE '^\s*$' | tail -1 | sed 's/^["'\'']//;s/["'\'']$//')"
        if [[ -z "$TEST_CMD" ]]; then
          echo "    Setup agent didn't return a clear command. Falling back to manual entry."
          read -r -p "    Enter the test command (or leave blank to skip): " TEST_CMD
        else
          echo "    Done. Test command: '$TEST_CMD'"
        fi
        TEST_FW="$(echo "$TEST_CMD" | awk '{print $1}')"
        ;;
      *) TEST_CMD="$ans"; TEST_FW="$(echo "$TEST_CMD" | awk '{print $1}')" ;;
    esac
  fi

  # report path
  read -r -p "  Where should HTML reports be saved? [docs/reports] " REPORT_PATH
  REPORT_PATH="${REPORT_PATH:-docs/reports}"

  write_config "$TEST_FW" "$TEST_CMD" "$DP" "$DI" "$REPORT_PATH" "$BASE" "$REPO"
  echo ""
  echo "  Config written to .claude/ioe-v3.local.md"
else
  # config exists — print confirmation
  echo ""
  echo "=== IOE v3 — existing config (.claude/ioe-v3.local.md) ==="
  sed -n '2,8p' "$CONFIG" | sed 's/^/  /'
  echo "  Proceeding to issue selection. (Re-run setup: --rebootstrap)"
fi

# --- read back the values we need for the launch (from config, so it's consistent)
TEST_CMD="$(grep -m1 '^test_command:' "$CONFIG" | sed 's/^test_command: *//')"
DESIGN_PRINCIPLES="$(grep -m1 '^design_principles:' "$CONFIG" | sed 's/^design_principles: *//')"
REPORT_PATH="$(grep -m1 '^report_path:' "$CONFIG" | sed 's/^report_path: *//')"

# --- build the startup message: a direct /tf run with clean, pre-parsed args
#     The model just executes this — nothing to parse, nothing to skip.
COMPLETED="[]"
STARTUP_MSG="/tf run ioe-v3 issue=\"$ISSUE\" base=\"$BASE\" test-command=\"$TEST_CMD\" design-principles=\"$DESIGN_PRINCIPLES\" report-path=\"$REPORT_PATH\" completed=\"$COMPLETED\" repo=\"$REPO\""

echo ""
echo "=== Launching pi ==="
echo "  startup: $STARTUP_MSG"
echo ""

# --- launch pi in the repo root with the startup message
#   --append-system-prompt loads the skill's blocked-run handling so the model
#   knows how to react when the flow blocks. The skill file itself is loaded
#   via --skill so /skill:ioe-v3 is available too.
exec pi --skill "$SCRIPT_DIR/skills" --append-system-prompt "$SCRIPT_DIR/skills/SKILL.md" "$STARTUP_MSG"
