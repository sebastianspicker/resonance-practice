#!/usr/bin/env bash
# Run the pinned SwiftLint binary in source-lint or compiled-analysis mode.
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
	;;
analyze)
	# Analyzer rules need full compiler invocations and live build products. The
	# integrated Swift driver logs only temporary response files, so build with
	# the legacy driver into a private derived-data directory and analyze it
	# before cleanup. Zero analyzed files means the analysis did not run.
	command -v xcodebuild >/dev/null || {
		echo "xcodebuild is required for Swift analysis." >&2
		exit 1
	}
	WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/resonance-swift-analyze.XXXXXX")"
	trap 'rm -rf "$WORK_DIR"' EXIT
	xcodebuild \
		-project ios/ResonanceApp/ResonanceApp.xcodeproj \
		-scheme ResonanceApp \
		-destination "generic/platform=iOS Simulator" \
		-derivedDataPath "$WORK_DIR/DerivedData" \
		SWIFT_USE_INTEGRATED_DRIVER=NO \
		build >"$WORK_DIR/xcodebuild.log" 2>&1 || {
		tail -40 "$WORK_DIR/xcodebuild.log" >&2
		exit 1
	}
	"$SWIFTLINT_BIN" analyze \
		--strict \
		--config .swiftlint.yml \
		--compiler-log-path "$WORK_DIR/xcodebuild.log" | tee "$WORK_DIR/analyze.log"
	if grep -Eq "in 0 files\.?$" "$WORK_DIR/analyze.log"; then
		echo "SwiftLint analyzed no files; refusing to report success." >&2
		exit 1
	fi
	;;
*)
	echo "Usage: ./scripts/lint-swift.sh [lint|analyze]" >&2
	exit 2
	;;
esac
