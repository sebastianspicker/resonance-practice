#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/ios/ResonanceApp"
PROJECT="$APP_DIR/ResonanceApp.xcodeproj"
SCHEME="ResonanceApp"
SCHEME_FILE="$PROJECT/xcshareddata/xcschemes/$SCHEME.xcscheme"

fail() {
	echo "iOS verification unavailable: $*" >&2
	exit 1
}

command -v xcodebuild >/dev/null || fail "xcodebuild is not installed."
command -v xcrun >/dev/null || fail "xcrun is not installed."
command -v jq >/dev/null || fail "jq is required to select an available iPhone simulator deterministically."
[[ -d "$PROJECT" ]] || fail "native project not found at $PROJECT."
[[ -f "$SCHEME_FILE" ]] || fail "shared scheme not found at $SCHEME_FILE."
find "$APP_DIR/Tests" -name '*.swift' -type f -print -quit | grep -q . || fail "no XCTest source files found under $APP_DIR/Tests."
grep -R -q --include='*.swift' 'func test' "$APP_DIR/Tests" || fail "no XCTest methods found under $APP_DIR/Tests."

if [[ -n "${IOS_DESTINATION:-}" ]]; then
	DESTINATION="$IOS_DESTINATION"
else
	SIMULATOR_ID="$(xcrun simctl list devices available -j | jq -r '
		.devices
		| to_entries
		| map(.value[])
		| map(select(.isAvailable == true and (.name | startswith("iPhone"))))
		| sort_by(.name, .udid)
		| .[0].udid // empty
	')"
	[[ -n "$SIMULATOR_ID" ]] || fail "no available iPhone simulator was found; set IOS_DESTINATION to override."
	DESTINATION="platform=iOS Simulator,id=$SIMULATOR_ID"
fi

DERIVED_DATA_PATH="$(mktemp -d "${TMPDIR:-/tmp}/resonance-ios-derived-data.XXXXXX")"
trap 'rm -rf "$DERIVED_DATA_PATH"' EXIT

echo "Running iOS XCTest via $PROJECT, scheme $SCHEME, destination $DESTINATION..."
xcodebuild \
	-project "$PROJECT" \
	-scheme "$SCHEME" \
	-destination "$DESTINATION" \
	-derivedDataPath "$DERIVED_DATA_PATH" \
	-parallel-testing-enabled NO \
	-quiet \
	test

echo "iOS XCTest passed for $DESTINATION."
