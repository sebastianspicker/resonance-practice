#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PATTERNS=(
  "server/dist/**"
  "server/node_modules/**"
  "ios/ResonanceApp/.build/**"
)

violations=0
for pattern in "${PATTERNS[@]}"; do
  if git ls-files -- "$pattern" | grep -q .; then
    echo "Tracked build artifact matches pattern: $pattern" >&2
    git ls-files -- "$pattern" >&2
    violations=1
  fi
done

if [[ "$violations" -ne 0 ]]; then
  echo "Build artifact guard failed." >&2
  exit 1
fi

echo "Build artifact guard passed."
