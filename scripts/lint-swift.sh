#!/usr/bin/env bash
# Run the pinned SwiftLint binary in lint or compiler-log analysis mode.
set -euo pipefail

EXPECTED_SWIFTLINT_VERSION="0.63.2"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-lint}"
SWIFTLINT_BIN="${SWIFTLINT_BIN:-swiftlint}"

if ! command -v "$SWIFTLINT_BIN" >/dev/null 2>&1; then
	echo "swiftlint ${EXPECTED_SWIFTLINT_VERSION} is required." >&2
	exit 1
fi

ACTIVE_VERSION="$("$SWIFTLINT_BIN" version)"
if [[ "$ACTIVE_VERSION" != "$EXPECTED_SWIFTLINT_VERSION" ]]; then
	echo "swiftlint ${EXPECTED_SWIFTLINT_VERSION} is required; found ${ACTIVE_VERSION}." >&2
	exit 1
fi

cd "$ROOT_DIR"

case "$MODE" in
lint)
	"$SWIFTLINT_BIN" lint --strict --no-cache --config .swiftlint.yml
	"$SWIFTLINT_BIN" lint --strict --no-cache --config .swiftlint-tests.yml
	;;
analyze)
	COMPILER_LOG_PATH="${2:-}"
	if [[ -z "$COMPILER_LOG_PATH" || ! -f "$COMPILER_LOG_PATH" ]]; then
		echo "Usage: ./scripts/lint-swift.sh analyze <xcodebuild-compiler-log>" >&2
		exit 2
	fi
	"$SWIFTLINT_BIN" analyze \
		--strict \
		--config .swiftlint.yml \
		--compiler-log-path "$COMPILER_LOG_PATH"
	;;
*)
	echo "Usage: ./scripts/lint-swift.sh [lint|analyze <xcodebuild-compiler-log>]" >&2
	exit 2
	;;
esac
