#!/usr/bin/env bash
# Prepare deterministic local dependencies and fixture data for the product demo.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SERVER_DIR="$ROOT_DIR/server"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_cmd node

cd "$ROOT_DIR"

export DATABASE_URL="${DATABASE_URL:-postgresql://resonance:resonance@localhost:5432/resonance}"
node ./scripts/assert-database-target.mjs --development

require_cmd docker
require_cmd npm
require_cmd curl

echo "[1/5] Validating demo fixture"
node ./scripts/demo/validate-fixture.mjs

echo "[2/5] Starting local infra (PostgreSQL + S3 storage)"
docker compose -f infra/docker-compose.yml up -d --wait postgres s3

cd "$SERVER_DIR"

echo "[3/5] Installing server dependencies"
npm ci

echo "[4/5] Applying migrations + seeding mock demo data"
npm run prisma:generate
npm run prisma:migrate
npm run prisma:seed:demo

cd "$ROOT_DIR"

echo "[5/5] Health checks"

if curl -fsS http://localhost:4000/ready >/dev/null 2>&1; then
  echo "- API readiness check: OK"
else
  echo "- API readiness check: SKIPPED (API not running or dependencies unavailable). Start with: cd server && npm run dev"
fi

echo ""
echo "Local pilot demo bootstrap complete."
echo "Next: open the app in Xcode, sign in via dev login, then use Settings > Debug > Load Mock Demo Data."
