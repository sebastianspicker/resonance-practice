#!/usr/bin/env bash
# Scan tracked and untracked publication candidates for credential-shaped content.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

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
scan_failed=0
candidate_files=()
while IFS= read -r -d '' path; do
  case "$path" in
  .env | .env.* | */.env | */.env.* | scripts/secret-scan.sh)
    continue
    ;;
  esac
  if [[ -L "$path" ]]; then
    echo "Secret scan requires manual review of publication-candidate symlink: $path" >&2
    scan_failed=1
    continue
  fi
  if [[ ! -e "$path" ]]; then
    continue
  fi
  if [[ ! -r "$path" ]]; then
    echo "Secret scan cannot read publication candidate: $path" >&2
    scan_failed=1
    continue
  fi
  candidate_files+=("$path")
done < <(git ls-files --cached --others --exclude-standard -z -- .)

if [[ "${#candidate_files[@]}" -eq 0 ]]; then
  echo "Secret scan found no publication candidates." >&2
  exit 2
fi

if command -v rg >/dev/null 2>&1; then
  scanner='rg'
elif command -v grep >/dev/null 2>&1; then
  scanner='grep'
else
  echo "Secret scan requires either rg or grep." >&2
  exit 2
fi

for pattern in "${patterns[@]}"; do
  set +e
  if [[ "$scanner" == 'rg' ]]; then
    matches="$(rg --files-with-matches --regexp "$pattern" -- "${candidate_files[@]}" 2>&1)"
  else
    matches="$(grep --extended-regexp --binary-files=without-match --files-with-matches -- "$pattern" "${candidate_files[@]}" 2>&1)"
  fi
  status=$?
  set -e
  case "$status" in
  0)
    echo "Potential secret pattern matched: $pattern" >&2
    while IFS= read -r path; do
      [[ -n "$path" ]] && echo "  $path" >&2
    done <<< "$matches"
    found=1
    ;;
  1)
    ;;
  *)
    echo "Secret scan could not inspect all publication candidates for pattern: $pattern" >&2
    [[ -n "$matches" ]] && echo "$matches" >&2
    scan_failed=1
    ;;
  esac
done

if [ "$scan_failed" -ne 0 ]; then
  echo "Secret scan incomplete." >&2
  exit 2
fi
if [ "$found" -ne 0 ]; then
  echo "Secret scan failed." >&2
  exit 1
fi

echo "Environment files were excluded from content inspection and require manual review."
echo "Secret scan passed."
