#!/usr/bin/env bash
set -euo pipefail

usage() {
	cat <<'USAGE'
Usage: ./scripts/ci-local.sh [--with-docker]

Runs the same repo checks as GitHub CI that are available locally.

Options:
  --with-docker   Start/stop Postgres and MinIO via docker compose for this run.
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
	echo "Starting Postgres and MinIO via docker compose..."
	docker compose -f infra/docker-compose.yml up -d postgres minio

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
	echo "Waiting for MinIO to be ready..."
	for _ in {1..30}; do
		if curl -fsS http://localhost:9000/minio/health/live >/dev/null 2>&1; then
			break
		fi
		sleep 1
	done
fi

export DATABASE_URL="${DATABASE_URL:-postgresql://resonance:resonance@localhost:5432/resonance_test}"
export PORT="${PORT:-4000}"
export AUTH_MODE="${AUTH_MODE:-dev}"
export JWT_SECRET="${JWT_SECRET:-CHANGE-ME-generate-a-real-secret-at-least-32-chars}"
export DEV_UNIVERSITY_NAME="${DEV_UNIVERSITY_NAME:-Mock University Conservatory}"
export DEV_LOGIN_CALLBACK_URL="${DEV_LOGIN_CALLBACK_URL:-resonance://auth-callback}"
export S3_ENDPOINT="${S3_ENDPOINT:-http://localhost:9000}"
export S3_REGION="${S3_REGION:-us-east-1}"
export S3_BUCKET="${S3_BUCKET:-resonance-dev}"
export S3_ACCESS_KEY="${S3_ACCESS_KEY:-minioadmin}"
export S3_SECRET_KEY="${S3_SECRET_KEY:-minioadmin}"
export S3_FORCE_PATH_STYLE="${S3_FORCE_PATH_STYLE:-true}"

echo "Validating docker compose config..."
docker compose -f infra/docker-compose.yml config -q

echo "Running secret scan..."
./scripts/secret-scan.sh

echo "Validating demo fixture..."
node ./scripts/demo/validate-fixture.mjs

echo "Checking committed build artifacts..."
./scripts/check-no-build-artifacts.sh

echo "Shellchecking Bash scripts..."
docker run --rm -v "$ROOT_DIR:/mnt" -w /mnt --entrypoint sh koalaman/shellcheck-alpine:stable -lc 'shellcheck -s bash scripts/*.sh scripts/demo/*.sh'

echo "Linting GitHub Actions workflows..."
docker run --rm -v "$ROOT_DIR:/repo" -w /repo rhysd/actionlint:1.7.7

echo "Installing dependencies..."
(cd server && npm ci)

echo "Linting..."
(cd server && npm run lint)

echo "Checking formatting..."
(cd server && npm run format:check)

echo "Dependency audit (high+ prod only)..."
(cd server && npm audit --audit-level=high --omit=dev)

echo "Generating Prisma client..."
(cd server && npm run prisma:generate)

echo "Running migrations..."
(cd server && npm run prisma:migrate)

echo "Typechecking..."
(cd server && npm run build)

echo "Running server health probe..."
SERVER_PID=""
cleanup_server() {
	if [[ -n "$SERVER_PID" ]]; then
		kill "$SERVER_PID" >/dev/null 2>&1 || true
	fi
}
(cd server && npm run start) >/tmp/resonance-server-local.log 2>&1 &
SERVER_PID=$!
for _ in {1..30}; do
	if curl -fsS "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
		break
	fi
	sleep 1
done
if ! curl -fsS "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
	cleanup_server
	cat /tmp/resonance-server-local.log >&2
	exit 1
fi
cleanup_server

echo "Running tests with coverage..."
(cd server && npx vitest run --coverage)

echo "Running process-level E2E tests..."
(cd server && npm run test:e2e)

echo "Running iOS simulator verification..."
./scripts/verify-ios.sh
