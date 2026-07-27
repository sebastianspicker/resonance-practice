#!/usr/bin/env bash
# Reproduce the local subset of CI, including guarded infrastructure setup.
set -euo pipefail

usage() {
	cat <<'USAGE'
Usage: ./scripts/ci-local.sh [--with-docker]

Runs the same repo checks as GitHub CI that are available locally.
Docker with a running daemon is required for Compose validation, ShellCheck,
and actionlint. Postgres and MinIO may instead be supplied externally.

Options:
  --with-docker   Start/stop Postgres and MinIO via docker compose for this run.
USAGE
}

WITH_DOCKER=0
while [[ "$#" -gt 0 ]]; do
	case "$1" in
	--help)
		usage
		exit 0
		;;
	--with-docker)
		WITH_DOCKER=1
		;;
	*)
		echo "Unknown argument: $1" >&2
		usage >&2
		exit 2
		;;
	esac
	shift
done

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if ! command -v node >/dev/null; then
	echo "node is required." >&2
	exit 1
fi

export DATABASE_URL="${DATABASE_URL:-postgresql://resonance:resonance@localhost:5432/resonance_test}"
node ./scripts/assert-test-database-url.mjs
node ./scripts/check-node-version.mjs

if ! command -v npm >/dev/null; then
	echo "npm is required." >&2
	exit 1
fi
if ! command -v docker >/dev/null; then
	echo "docker is required for Compose validation, ShellCheck, and actionlint." >&2
	exit 1
fi
if ! docker info >/dev/null 2>&1; then
	echo "A running Docker daemon is required for local CI checks." >&2
	exit 1
fi

SERVER_PID=""
COMPOSE_STARTED=0

stop_server() {
	local pid="$SERVER_PID"
	if [[ -z "$pid" ]]; then
		return
	fi

	if kill -0 "$pid" >/dev/null 2>&1; then
		echo "Stopping local API server (PID $pid)..."
		kill -TERM "$pid" >/dev/null 2>&1 || true
		# Allow the server's three independent five-second shutdown budgets.
		for _ in {1..20}; do
			if ! kill -0 "$pid" >/dev/null 2>&1; then
				break
			fi
			sleep 1
		done
		if kill -0 "$pid" >/dev/null 2>&1; then
			echo "API server did not stop after 20 seconds; terminating its child process." >&2
			kill -KILL "$pid" >/dev/null 2>&1 || true
		fi
	fi

	wait "$pid" >/dev/null 2>&1 || true
	SERVER_PID=""
}

cleanup() {
	local status=$?
	trap - EXIT INT TERM
	stop_server
	if [[ "$COMPOSE_STARTED" -eq 1 ]]; then
		echo "Stopping Postgres and MinIO via docker compose..."
		docker compose -f infra/docker-compose.yml down >/dev/null 2>&1 || true
	fi
	exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

ensure_test_database() {
	local database_exists
	database_exists="$(docker compose -f infra/docker-compose.yml exec -T postgres \
		psql -U resonance -d postgres -tAc \
		"SELECT 1 FROM pg_database WHERE datname = 'resonance_test'" 2>/dev/null || true)"
	if [[ "$database_exists" != "1" ]]; then
		echo "Creating local CI database resonance_test..."
		docker compose -f infra/docker-compose.yml exec -T postgres \
			psql -U resonance -d postgres -v ON_ERROR_STOP=1 -c 'CREATE DATABASE resonance_test'
	fi
	docker compose -f infra/docker-compose.yml exec -T postgres \
		psql -U resonance -d resonance_test -v ON_ERROR_STOP=1 -c 'SELECT 1' >/dev/null
}

if [[ "$WITH_DOCKER" -eq 1 ]]; then
	echo "Starting Postgres and MinIO via docker compose..."
	COMPOSE_STARTED=1
	docker compose -f infra/docker-compose.yml up -d postgres minio

	echo "Waiting for Postgres to be ready..."
	POSTGRES_READY=0
	for _ in {1..30}; do
		if docker compose -f infra/docker-compose.yml exec -T postgres pg_isready -U resonance >/dev/null 2>&1; then
			POSTGRES_READY=1
			break
		fi
		sleep 1
	done
	if [[ "$POSTGRES_READY" -ne 1 ]]; then
		echo "Postgres did not become ready within 30 seconds." >&2
		exit 1
	fi
	ensure_test_database
	echo "Waiting for MinIO to be ready..."
	MINIO_READY=0
	for _ in {1..30}; do
		if curl -fsS http://localhost:9000/minio/health/live >/dev/null 2>&1; then
			MINIO_READY=1
			break
		fi
		sleep 1
	done
	if [[ "$MINIO_READY" -ne 1 ]]; then
		echo "MinIO did not become ready within 30 seconds." >&2
		exit 1
	fi
fi

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

echo "Validating public documentation and screenshots..."
node ./scripts/validate-public-docs.mjs

echo "Testing repository policy scripts..."
node --test tests/repository/*.test.mjs

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

echo "Checking dead code..."
(cd server && npm run quality:dead-code)

echo "Checking source duplication..."
(cd server && npm run quality:duplicates)

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

echo "Running server readiness probe..."
(cd server && exec node dist/index.js) >/tmp/resonance-server-local.log 2>&1 &
SERVER_PID=$!
for _ in {1..30}; do
	if curl -fsS "http://127.0.0.1:${PORT}/ready" >/dev/null 2>&1; then
		break
	fi
	sleep 1
done
if ! curl -fsS "http://127.0.0.1:${PORT}/ready" >/dev/null 2>&1; then
	cat /tmp/resonance-server-local.log >&2
	exit 1
fi
stop_server

echo "Running tests with coverage..."
(cd server && npx vitest run --coverage)

echo "Running process-level E2E tests..."
(cd server && npm run test:e2e)

echo "Linting Swift sources and tests..."
./scripts/lint-swift.sh lint

echo "Running iOS simulator verification..."
IOS_COMPILER_LOG_PATH="${TMPDIR:-/tmp}/resonance-xcodebuild.log" ./scripts/verify-ios.sh

echo "Analyzing compiled Swift..."
./scripts/lint-swift.sh analyze "${TMPDIR:-/tmp}/resonance-xcodebuild.log"

if xcrun --toolchain swift swift --version 2>/dev/null | grep -Fq "Swift version 6.3.3"; then
	echo "Running exact Swift 6.3.3 simulator verification..."
	IOS_TOOLCHAIN=swift IOS_EXPECTED_SWIFT_VERSION=6.3.3 ./scripts/verify-ios.sh
else
	echo "Swift 6.3.3 custom toolchain is required; run ./scripts/install-swift-toolchain.sh." >&2
	exit 1
fi
