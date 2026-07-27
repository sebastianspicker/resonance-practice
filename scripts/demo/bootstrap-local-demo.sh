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
node ./scripts/assert-demo-database-url.mjs

require_cmd docker
require_cmd npm
require_cmd curl

echo "[1/6] Validating demo fixture"
node ./scripts/demo/validate-fixture.mjs

echo "[2/6] Starting local infra (Postgres + MinIO)"
docker compose -f infra/docker-compose.yml up -d postgres minio

echo "[3/6] Waiting for Postgres readiness"
POSTGRES_READY=0
for _ in {1..40}; do
  if docker compose -f infra/docker-compose.yml exec -T postgres pg_isready -U resonance >/dev/null 2>&1; then
    POSTGRES_READY=1
    break
  fi
  sleep 1
done
if [[ "$POSTGRES_READY" -ne 1 ]]; then
  echo "Postgres did not become ready within 40 seconds." >&2
  exit 1
fi

echo "[3/6] Waiting for MinIO readiness"
MINIO_READY=0
for _ in {1..40}; do
  if curl -fsS http://localhost:9000/minio/health/live >/dev/null 2>&1; then
    MINIO_READY=1
    break
  fi
  sleep 1
done
if [[ "$MINIO_READY" -ne 1 ]]; then
  echo "MinIO did not become ready within 40 seconds." >&2
  exit 1
fi

cd "$SERVER_DIR"

echo "[4/6] Installing server dependencies"
npm ci

echo "[5/6] Applying migrations + seeding mock demo data"
npm run prisma:generate
npm run prisma:migrate
npm run prisma:seed:demo

cd "$ROOT_DIR"

echo "[6/6] Health checks"
echo "- MinIO health check: OK"

if curl -fsS http://localhost:4000/ready >/dev/null 2>&1; then
  echo "- API readiness check: OK"
else
  echo "- API readiness check: SKIPPED (API not running or dependencies unavailable). Start with: cd server && npm run dev"
fi

echo ""
echo "Local pilot demo bootstrap complete."
echo "Next: open the app in Xcode, sign in via dev login, then use Settings > Debug > Load Mock Demo Data."
