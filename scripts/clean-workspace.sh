#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
fi

TARGETS=(
  "server/node_modules"
  "server/dist"
  "server/.vitest"
  "server/coverage"
  "server/test-results"
  "ios/ResonanceApp/.build"
  "test-results"
  "reports"
)

remove_path() {
  local path="$1"
  if [[ -e "$path" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      echo "[dry-run] remove $path"
    else
      rm -rf "$path"
      echo "removed $path"
    fi
  fi
}

for target in "${TARGETS[@]}"; do
  remove_path "$target"
done

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "Dry run complete."
else
  echo "Workspace cleanup complete."
fi
