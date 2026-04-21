#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SERVER_DIR="$ROOT_DIR/server"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_cmd docker
require_cmd npm
require_cmd node
require_cmd curl

cd "$ROOT_DIR"

echo "[1/6] Validating demo fixture"
node ./scripts/demo/validate-fixture.mjs

echo "[2/6] Starting local infra (Postgres + MinIO)"
docker compose -f infra/docker-compose.yml up -d postgres minio

echo "[3/6] Waiting for Postgres readiness"
for _ in {1..40}; do
  if docker compose -f infra/docker-compose.yml exec -T postgres pg_isready -U resonance >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

cd "$SERVER_DIR"

export DATABASE_URL="${DATABASE_URL:-postgresql://resonance:resonance@localhost:5432/resonance}"

echo "[4/6] Installing server dependencies"
npm ci

echo "[5/6] Applying migrations + seeding mock demo data"
npm run prisma:generate
npm run prisma:migrate
npm run prisma:seed:demo

cd "$ROOT_DIR"

echo "[6/6] Health checks"
if curl -fsS http://localhost:9000/minio/health/live >/dev/null 2>&1; then
  echo "- MinIO health check: OK"
else
  echo "- MinIO health check: FAILED" >&2
fi

if curl -fsS http://localhost:4000/health >/dev/null 2>&1; then
  echo "- API health check: OK"
else
  echo "- API health check: SKIPPED (API not running). Start with: cd server && npm run dev"
fi

echo ""
echo "Local RC demo bootstrap complete."
echo "Next: open the app in Xcode, sign in via dev login, then use Settings > Debug > Load Mock Demo Data."
