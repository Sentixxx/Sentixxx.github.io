#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
LLM_DIR="$ROOT_DIR/_llm"
TASK_DIR="$LLM_DIR/_tasks"

usage() {
  cat <<'USAGE'
Usage:
  scripts/llm-wiki.sh [init]
  scripts/llm-wiki.sh run [--cli codex|claude] "<task>"
  scripts/llm-wiki.sh task "<task>"

Environment:
  LLM_MODE=cli|api|task   (default: cli)
  LLM_CLI=codex|claude    (override CLI selection)
  LLM_CLI_CMD="..."       (optional custom CLI command, reads prompt from stdin)
  LLM_API_URL=...         (API endpoint, required for api mode)
  LLM_MODEL=...           (model name, required for api mode)
  OPENAI_API_KEY=...      (optional auth header for api mode)
USAGE
}

ensure_file() {
  local path="$1"
  local content="$2"
  if [[ ! -f "$path" ]]; then
    printf "%s" "$content" > "$path"
  fi
}

ensure_init() {
  mkdir -p "$LLM_DIR/wiki" "$LLM_DIR/_specs" "$TASK_DIR"

  ensure_file "$LLM_DIR/SCHEMA.md" "# LLM Wiki Schema

## Purpose
This repository contains a private, LLM-maintained wiki. The LLM is responsible for maintaining the wiki layer, while raw sources are read-only.

## Directory Layout
- Raw sources (read-only):
  - _Inbox/
  - _posts/
- Wiki (LLM writes here):
  - _llm/wiki/
- Index and log:
  - _llm/index.md
  - _llm/log.md
- This schema:
  - _llm/SCHEMA.md

## Rules
1. Do not modify raw sources under _Inbox/ or _posts/.
2. Write all generated content under _llm/wiki/.
3. Always update _llm/index.md when new pages are created or updated.
4. Always append to _llm/log.md for each ingest, query, or lint pass.

## Ingest Workflow
When a new source is added to raw sources:
1. Read the source.
2. Create or update relevant wiki pages in _llm/wiki/.
3. Update _llm/index.md with links and one-line summaries.
4. Append a log entry to _llm/log.md.

## Query Workflow
When asked a question:
1. Consult _llm/index.md to locate relevant pages.
2. Read and synthesize from wiki pages.
3. If the answer adds durable value, write a new wiki page and update index/log.

## Lint Workflow
Periodically check for:
- Contradictions between pages
- Orphan pages
- Missing cross-links
- Stale claims that should be updated
Log findings and fixes.

## Index Conventions
- Group by category (entities, concepts, sources, etc.).
- Each entry is a markdown link with a one-line summary.

## Log Conventions
- Append-only.
- Prefix each entry as:
  - ## [YYYY-MM-DD] <action> | <title>

## Tools and Hints
- If available, the obsidian CLI can be used to open or inspect the vault.
- Use git log to review recent changes and derive context for updates.
"

  ensure_file "$LLM_DIR/README.md" "# LLM Wiki (Private)

This directory hosts a private LLM-maintained wiki. It is intentionally excluded from Hexo publishing.

## Layout
- SCHEMA.md: Single source of truth for rules and workflows.
- wiki/: Generated wiki pages.
- index.md: Index of wiki pages.
- log.md: Append-only activity log.
- _specs/: Internal design documents.

## Raw Sources
The LLM reads from (read-only):
- _Inbox/
- _posts/

## Usage
Initialize structure and symlinks:
  scripts/llm-wiki.sh init

Run a task using CLI (default):
  scripts/llm-wiki.sh run \"ingest _Inbox/example.md\"

Select CLI explicitly:
  scripts/llm-wiki.sh run --cli codex \"lint wiki\"
  scripts/llm-wiki.sh run --cli claude \"summarize recent changes\"
"

  ensure_file "$LLM_DIR/index.md" "# LLM Wiki Index

## Overview
This index catalogs all wiki pages. Update this file whenever pages are created or changed.

## Entities

## Concepts

## Sources

## Other
"

  if [[ ! -f "$LLM_DIR/log.md" ]]; then
    printf "# LLM Wiki Log\n\n## [%s] init | LLM Wiki structure created\n" "$(date +%Y-%m-%d)" > "$LLM_DIR/log.md"
  fi

  if [[ -e "$ROOT_DIR/AGENTS.md" && ! -L "$ROOT_DIR/AGENTS.md" ]]; then
    echo "AGENTS.md exists and is not a symlink; please resolve manually." >&2
  else
    ln -sfn "$LLM_DIR/SCHEMA.md" "$ROOT_DIR/AGENTS.md"
  fi

  if [[ -e "$ROOT_DIR/CLAUDE.md" && ! -L "$ROOT_DIR/CLAUDE.md" ]]; then
    echo "CLAUDE.md exists and is not a symlink; please resolve manually." >&2
  else
    ln -sfn "$LLM_DIR/SCHEMA.md" "$ROOT_DIR/CLAUDE.md"
  fi
}

build_prompt() {
  local task="$1"
  cat <<EOF
You are maintaining a private LLM wiki inside this repo.

Constraints:
- Raw sources are read-only: _Inbox/, _posts/
- Write only under _llm/wiki/, and update _llm/index.md and _llm/log.md
- Keep _llm/log.md append-only; use headings like: ## [YYYY-MM-DD] <action> | <title>

Helpful tools:
- If available, the obsidian CLI can be used to inspect the vault.
- Use git log to review recent changes and derive context for updates.

Task:
$task
EOF
}

select_cli() {
  local cli_choice="$1"
  if [[ -n "$cli_choice" ]]; then
    echo "$cli_choice"
    return 0
  fi
  if command -v codex >/dev/null 2>&1; then
    echo "codex"
    return 0
  fi
  if command -v claude >/dev/null 2>&1; then
    echo "claude"
    return 0
  fi
  echo ""
}

run_cli() {
  local cli="$1"
  local prompt="$2"

  if [[ -n "${LLM_CLI_CMD:-}" ]]; then
    printf "%s" "$prompt" | bash -lc "$LLM_CLI_CMD"
    return 0
  fi

  if [[ "$cli" == "codex" || "$cli" == "claude" ]]; then
    printf "%s" "$prompt" | "$cli"
    return 0
  fi

  echo "Unsupported CLI: $cli" >&2
  return 1
}

run_api() {
  local prompt="$1"
  if [[ -z "${LLM_API_URL:-}" ]]; then
    echo "LLM_API_URL is required for api mode" >&2
    return 1
  fi
  if [[ -z "${LLM_MODEL:-}" ]]; then
    echo "LLM_MODEL is required for api mode" >&2
    return 1
  fi

  export LLM_PROMPT="$prompt"
  local payload
  payload=$(python - <<'PY'
import json, os, sys
model = os.environ.get("LLM_MODEL")
if not model:
    print("missing model", file=sys.stderr)
    sys.exit(2)
prompt = os.environ.get("LLM_PROMPT", "")
print(json.dumps({"model": model, "messages": [{"role": "user", "content": prompt}]}))
PY
  )

  local auth_args=()
  if [[ -n "${OPENAI_API_KEY:-}" ]]; then
    auth_args=( -H "Authorization: Bearer ${OPENAI_API_KEY}" )
  fi

  curl -sS "$LLM_API_URL" \
    -H "Content-Type: application/json" \
    "${auth_args[@]}" \
    -d "$payload"
}

main() {
  local cmd="init"
  local cli_choice="${LLM_CLI:-}"

  if [[ $# -gt 0 && "$1" != --* ]]; then
    cmd="$1"
    shift
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cli)
        cli_choice="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      --)
        shift
        break
        ;;
      *)
        break
        ;;
    esac
  done

  case "$cmd" in
    init)
      ensure_init
      ;;
    run|task)
      ensure_init
      if [[ $# -lt 1 ]]; then
        echo "Task is required." >&2
        usage
        exit 1
      fi
      local task="$*"
      local prompt
      prompt=$(build_prompt "$task")
      local task_file="$TASK_DIR/$(date +%Y%m%d-%H%M%S)-task.md"
      printf "%s" "$prompt" > "$task_file"

      local mode="${LLM_MODE:-cli}"
      if [[ "$cmd" == "task" || "$mode" == "task" ]]; then
        echo "Task written to $task_file"
        exit 0
      fi

      if [[ "$mode" == "cli" ]]; then
        local cli
        cli=$(select_cli "$cli_choice")
        if [[ -z "$cli" ]]; then
          echo "No CLI found. Install codex or claude, or set LLM_CLI_CMD." >&2
          exit 1
        fi
        run_cli "$cli" "$prompt"
        exit $?
      fi

      if [[ "$mode" == "api" ]]; then
        run_api "$prompt"
        exit $?
      fi

      echo "Unknown mode: $mode" >&2
      exit 1
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
