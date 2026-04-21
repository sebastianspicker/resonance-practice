#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: ./scripts/ci-local.sh [--with-docker]

Runs the same checks as GitHub CI for the server.

Options:
  --with-docker   Start/stop Postgres via docker compose for this run.
USAGE
}

WITH_DOCKER=0
if [[ "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi
if [[ "${1:-}" == "--with-docker" ]]; then
  WITH_DOCKER=1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if ! command -v node >/dev/null; then
  echo "node is required." >&2
  exit 1
fi
if ! command -v npm >/dev/null; then
  echo "npm is required." >&2
  exit 1
fi

if [[ "$WITH_DOCKER" -eq 1 ]]; then
  if ! command -v docker >/dev/null; then
    echo "docker is required for --with-docker." >&2
    exit 1
  fi
  echo "Starting Postgres via docker compose..."
  docker compose -f infra/docker-compose.yml up -d postgres

  cleanup() {
    echo "Stopping Postgres via docker compose..."
    docker compose -f infra/docker-compose.yml down
  }
  trap cleanup EXIT

  echo "Waiting for Postgres to be ready..."
  for _ in {1..30}; do
    if docker compose -f infra/docker-compose.yml exec -T postgres pg_isready -U resonance >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
fi

export DATABASE_URL="${DATABASE_URL:-postgresql://resonance:resonance@localhost:5432/resonance}"

echo "Validating docker compose config..."
docker compose -f infra/docker-compose.yml config -q

echo "Running secret scan..."
./scripts/secret-scan.sh

echo "Validating demo fixture..."
node ./scripts/demo/validate-fixture.mjs

echo "Checking committed build artifacts..."
./scripts/check-no-build-artifacts.sh

echo "Installing dependencies..."
( cd server && npm ci )

echo "Linting..."
( cd server && npm run lint )

echo "Checking formatting..."
( cd server && npm run format:check )

echo "Dependency audit (high+ prod only)..."
( cd server && npm audit --audit-level=high --omit=dev )

echo "Generating Prisma client..."
( cd server && npm run prisma:generate )

echo "Running migrations..."
( cd server && npm run prisma:migrate )

echo "Typechecking..."
( cd server && npm run build )

echo "Running tests with coverage..."
( cd server && npx vitest run --coverage )
