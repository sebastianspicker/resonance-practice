#!/usr/bin/env bash
# Reproduce the GitHub CI lanes locally, including guarded infrastructure setup.
set -euo pipefail

usage() {
	cat <<'USAGE'
Usage: ./scripts/ci-local.sh [--with-docker]

Runs the same repository, server, and iOS checks as GitHub CI.
A running Docker daemon is required for Compose validation, ShellCheck, and
actionlint. PostgreSQL and S3-compatible storage may instead be supplied
externally through DATABASE_URL and the S3_* variables.

Options:
  --with-docker   Start and stop PostgreSQL and S3 storage via Docker Compose.
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
COMPOSE=(docker compose -f infra/docker-compose.yml)
LOG_DIR="${TMPDIR:-/tmp}"

for command in node npm docker curl; do
	command -v "$command" >/dev/null || {
		echo "$command is required." >&2
		exit 1
	}
done
docker info >/dev/null 2>&1 || {
	echo "A running Docker daemon is required for local CI checks." >&2
	exit 1
}

export DATABASE_URL="${DATABASE_URL:-postgresql://resonance:resonance@localhost:5432/resonance_test}"
node ./scripts/assert-database-target.mjs
./scripts/verify-repository.sh

SERVER_PID=""
COMPOSE_STARTED=0

# Stop the readiness-probe server, escalating to SIGKILL after 20 seconds.
stop_server() {
	[[ -n "$SERVER_PID" ]] || return 0
	if kill -0 "$SERVER_PID" >/dev/null 2>&1; then
		echo "Stopping local API server (PID $SERVER_PID)..."
		kill -TERM "$SERVER_PID" >/dev/null 2>&1 || true
		for _ in {1..20}; do
			kill -0 "$SERVER_PID" >/dev/null 2>&1 || break
			sleep 1
		done
		if kill -0 "$SERVER_PID" >/dev/null 2>&1; then
			echo "API server did not stop after 20 seconds; terminating it." >&2
			kill -KILL "$SERVER_PID" >/dev/null 2>&1 || true
		fi
	fi
	wait "$SERVER_PID" >/dev/null 2>&1 || true
	SERVER_PID=""
}

# shellcheck disable=SC2329 # Invoked through the EXIT trap.
cleanup() {
	local status=$?
	trap - EXIT INT TERM
	stop_server
	if [[ "$COMPOSE_STARTED" -eq 1 ]]; then
		echo "Stopping PostgreSQL and S3 storage via Docker Compose..."
		"${COMPOSE[@]}" down >/dev/null 2>&1 || true
	fi
	exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

ensure_test_database() {
	local database_exists
	database_exists="$("${COMPOSE[@]}" exec -T postgres \
		psql -U resonance -d postgres -tAc \
		"SELECT 1 FROM pg_database WHERE datname = 'resonance_test'" 2>/dev/null || true)"
	if [[ "$database_exists" != "1" ]]; then
		echo "Creating local CI database resonance_test..."
		"${COMPOSE[@]}" exec -T postgres \
			psql -U resonance -d postgres -v ON_ERROR_STOP=1 -c 'CREATE DATABASE resonance_test'
	fi
}

if [[ "$WITH_DOCKER" -eq 1 ]]; then
	echo "Starting PostgreSQL and S3 storage via Docker Compose..."
	COMPOSE_STARTED=1
	"${COMPOSE[@]}" up -d --wait postgres s3
	ensure_test_database
fi

export PORT="${PORT:-4000}"
export AUTH_MODE="${AUTH_MODE:-dev}"
export JWT_SECRET="${JWT_SECRET:-local-ci-access-secret-at-least-32-characters}"
export JWT_REFRESH_SECRET="${JWT_REFRESH_SECRET:-local-ci-refresh-secret-at-least-32-characters}"
export DEV_UNIVERSITY_NAME="${DEV_UNIVERSITY_NAME:-Mock University Conservatory}"
export DEV_LOGIN_CALLBACK_URL="${DEV_LOGIN_CALLBACK_URL:-resonance://auth-callback}"
export S3_ENDPOINT="${S3_ENDPOINT:-http://localhost:9000}"
export S3_REGION="${S3_REGION:-us-east-1}"
export S3_BUCKET="${S3_BUCKET:-resonance-dev}"
export S3_ACCESS_KEY="${S3_ACCESS_KEY:-minioadmin}"
export S3_SECRET_KEY="${S3_SECRET_KEY:-minioadmin}"
export S3_FORCE_PATH_STYLE="${S3_FORCE_PATH_STYLE:-true}"

echo "Validating Docker Compose config..."
"${COMPOSE[@]}" config -q

echo "Shellchecking Bash scripts..."
docker run --rm -v "$ROOT_DIR:/mnt" -w /mnt --entrypoint sh koalaman/shellcheck-alpine:stable -lc 'shellcheck -s bash scripts/*.sh scripts/demo/*.sh'

echo "Linting GitHub Actions workflows..."
docker run --rm -v "$ROOT_DIR:/repo" -w /repo rhysd/actionlint:1.7.12

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

echo "Typechecking sources, tests, seeds, and benchmarks..."
(cd server && npm run typecheck)

echo "Building..."
(cd server && npm run build)

echo "Running server readiness probe..."
(cd server && exec node dist/app/index.js) >"$LOG_DIR/resonance-server-local.log" 2>&1 &
SERVER_PID=$!
READY=0
for _ in {1..30}; do
	if curl -fsS "http://127.0.0.1:${PORT}/ready" >/dev/null 2>&1; then
		READY=1
		break
	fi
	sleep 1
done
if [[ "$READY" -ne 1 ]]; then
	cat "$LOG_DIR/resonance-server-local.log" >&2
	exit 1
fi
stop_server

echo "Running compact server suite..."
(cd server && npm test)

echo "Linting Swift sources and tests..."
./scripts/lint-swift.sh lint

echo "Running iOS simulator verification..."
./scripts/verify-ios.sh

echo "Analyzing compiled Swift..."
./scripts/lint-swift.sh analyze

if xcrun --toolchain swift swift --version 2>/dev/null | grep -Fq "Swift version 6.3.3"; then
	echo "Running exact Swift 6.3.3 simulator verification..."
	IOS_TOOLCHAIN=swift IOS_EXPECTED_SWIFT_VERSION=6.3.3 ./scripts/verify-ios.sh
else
	echo "Swift 6.3.3 custom toolchain is required; run ./scripts/install-swift-toolchain.sh." >&2
	exit 1
fi
