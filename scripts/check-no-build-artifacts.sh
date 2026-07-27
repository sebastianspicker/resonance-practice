#!/usr/bin/env bash
# Reject generated artifacts and stale report surfaces from the source tree.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PATTERNS=(
  "server/dist/**"
  "server/node_modules/**"
  "ios/ResonanceApp/.build/**"
  ".codacy/generated/**"
  ".codacy/logs/**"
  ".codacy/tmp/**"
  ".codacy/tools-configs/**"
  ".codacy/cli-config.yaml"
  ".codacy/codacy.yaml"
  ".codacy/codacy.config.json"
  ".codacy/configure-*.json"
  ".codacy/*-summary.json"
  ".codegraph/**"
  ".serena/**"
  ".claude/**"
  ".codex/**"
  ".cursor/**"
  ".kilo/**"
  ".agent/**"
  ".agents/**"
  ".continue/**"
  ".opencode/**"
  ".aider.conf.yml"
  ".aider.chat.history.md"
  ".aider.input.history"
  ".cursorrules"
  ".windsurfrules"
  "CLAUDE.md"
  "CODEX.md"
  "GEMINI.md"
  ".github/copilot-instructions.md"
  ".tmp/**"
  "artifacts/**"
  "docs/archive/**"
  "docs/assets/screenshots/local/**"
  "docs/assets/screenshots/rc/**"
  "docs/assets/screenshots/retired/**"
  "deprecated/**"
  "DECISIONS.md"
  "FINDINGS.md"
  "LOG.md"
  "AUDIT.md"
  "PUBLIC_ALPHA_AUDIT.md"
  "REFACTOR_PLAN.md"
  "RELEASE_STATUS.md"
  "REMEDIATION.md"
  "STATUS.md"
  "PLAN.md"
  "plan.md"
  "LEDGER.md"
  "AGENT.md"
  "progress.md"
  "docs/architecture-map.md"
  "docs/code-index.md"
  "docs/refactor-plan.md"
  "docs/verification-baseline.md"
  "docs/agent/**"
  "*.log"
  "**/.DS_Store"
  "AGENTS.md"
  "internal/**"
  "private/**"
  "privat/**"
)

violations=0
repository_files=()
while IFS= read -r -d '' path; do
  if [[ -e "$path" || -L "$path" ]]; then
    repository_files+=("$path")
  fi
done < <(git ls-files --cached --others --exclude-standard -z -- .)

for pattern in "${PATTERNS[@]}"; do
  for path in "${repository_files[@]}"; do
    # shellcheck disable=SC2254 # Patterns intentionally contain repository globs.
    case "$path" in
    $pattern)
      echo "Publication-boundary violation matches pattern: $pattern" >&2
      echo "$path" >&2
      violations=1
      ;;
    esac
  done
done

if [[ "$violations" -ne 0 ]]; then
  echo "Publication-boundary guard failed." >&2
  exit 1
fi

echo "Publication-boundary guard passed."
