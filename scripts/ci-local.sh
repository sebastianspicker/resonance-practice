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
# shellcheck source=scripts/lib/ci-local-workflow.sh
source "$ROOT_DIR/scripts/lib/ci-local-workflow.sh"

run_ci_local_workflow "$ROOT_DIR" "$WITH_DOCKER"
