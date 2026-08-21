#!/usr/bin/env bash
# Remove ignored/generated workspace outputs while preserving tracked source and approved evidence.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

DRY_RUN=0
case "$#" in
  0) ;;
  1)
    if [[ "$1" == "--dry-run" ]]; then
      DRY_RUN=1
    else
      echo "Unknown argument: $1" >&2
      echo "Usage: ./scripts/clean-workspace.sh [--dry-run]" >&2
      exit 2
    fi
    ;;
  *)
    echo "Usage: ./scripts/clean-workspace.sh [--dry-run]" >&2
    exit 2
    ;;
esac

TARGETS=(
  "server/node_modules"
  "server/dist"
  "node_modules"
  "ios/ResonanceApp/.build"
  ".codacy/generated"
  ".codacy/logs"
  ".codacy/tmp"
  ".codacy/cache"
  ".codacy/tools-configs"
  ".codacy/cli-config.yaml"
  ".codacy/codacy.yaml"
  ".codacy/codacy.config.json"
  ".codegraph"
  ".serena"
  ".tmp"
  "artifacts"
  "deprecated"
  "RELEASE_STATUS.md"
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

while IFS= read -r -d '' metadata_file; do
  remove_path "${metadata_file#./}"
done < <(find . -name .DS_Store -type f -print0)

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "Dry run complete."
else
  echo "Workspace cleanup complete."
fi
