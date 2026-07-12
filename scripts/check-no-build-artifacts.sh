#!/usr/bin/env bash
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
  "docs/archive/**"
  "docs/assets/screenshots/rc/**"
  "AGENTS.md"
  "internal/**"
  "private/**"
  "privat/**"
)

violations=0
for pattern in "${PATTERNS[@]}"; do
  matches="$(git ls-files -- "$pattern")"
  while IFS= read -r path; do
    if [[ -n "$path" && -e "$path" ]]; then
      echo "Tracked publication-boundary violation matches pattern: $pattern" >&2
      echo "$path" >&2
      violations=1
    fi
  done <<< "$matches"
done

if [[ "$violations" -ne 0 ]]; then
  echo "Publication-boundary guard failed." >&2
  exit 1
fi

echo "Publication-boundary guard passed."
