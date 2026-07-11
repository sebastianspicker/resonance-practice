#!/usr/bin/env bash
set -euo pipefail

key_block_begin='-----BEGIN'
patterns=(
  "${key_block_begin} (RSA|EC|DSA|OPENSSH) PRIVATE KEY-----"
  "${key_block_begin} PRIVATE KEY-----"
  "${key_block_begin} PGP PRIVATE KEY BLOCK-----"
  'AKIA[0-9A-Z]{16}'
  'ASIA[0-9A-Z]{16}'
  'ghp_[0-9A-Za-z]{36}'
  'github_pat_[0-9A-Za-z_]{22,}'
  'xox[baprs]-[0-9A-Za-z-]{10,}'
  'AIza[0-9A-Za-z_-]{35}'
  'sk_(live|test)_[0-9A-Za-z]{10,}'
)

found=0
exclude_paths=(
  "scripts/secret-scan.sh"
)
exclude_args=()
for path in "${exclude_paths[@]}"; do
  exclude_args+=(":!${path}")
done
for pattern in "${patterns[@]}"; do
  if git grep -nE -e "$pattern" -- . "${exclude_args[@]}" >/dev/null; then
    echo "Potential secret pattern matched: $pattern" >&2
    git grep -nE -e "$pattern" -- . "${exclude_args[@]}" >&2 || true
    found=1
  fi
done

if [ "$found" -ne 0 ]; then
  echo "Secret scan failed." >&2
  exit 1
fi

echo "Secret scan passed."
