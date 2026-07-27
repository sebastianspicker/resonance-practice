#!/usr/bin/env bash
# Reset only guarded local demo data through the Prisma demo-reset command.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SERVER_DIR="$ROOT_DIR/server"

if ! command -v npm >/dev/null 2>&1; then
  echo "Missing required command: npm" >&2
  exit 1
fi

cd "$SERVER_DIR"

export DATABASE_URL="${DATABASE_URL:-postgresql://resonance:resonance@localhost:5432/resonance}"

npm run demo:reset

echo "Demo database records removed (demo_* prefix)."
echo "If needed, reseed with: npm run prisma:seed:demo"
