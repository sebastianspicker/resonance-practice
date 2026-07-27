#!/usr/bin/env bash
# Verify the iOS app with its required Swift toolchain and shared Xcode scheme.
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

TOOLCHAIN_ARGS=()
SWIFT_VERSION_COMMAND=(xcrun swift --version)
if [[ -n "${IOS_TOOLCHAIN:-}" ]]; then
	# Swift.org toolchains need this flag to load Xcode SDK cross-import
	# overlays such as the SwiftData and SwiftUI integration.
	TOOLCHAIN_ARGS=(
		-toolchain "$IOS_TOOLCHAIN"
		"OTHER_SWIFT_FLAGS=\$(inherited) -Xfrontend -enable-cross-import-overlays"
	)
	SWIFT_VERSION_COMMAND=(xcrun --toolchain "$IOS_TOOLCHAIN" swift --version)
fi

if [[ -n "${IOS_EXPECTED_SWIFT_VERSION:-}" ]]; then
	SWIFT_VERSION_OUTPUT="$("${SWIFT_VERSION_COMMAND[@]}")"
	if ! grep -Fq "Swift version ${IOS_EXPECTED_SWIFT_VERSION}" <<<"$SWIFT_VERSION_OUTPUT"; then
		echo "$SWIFT_VERSION_OUTPUT" >&2
		fail "expected Swift ${IOS_EXPECTED_SWIFT_VERSION}."
	fi
fi

echo "Running iOS XCTest via $PROJECT, scheme $SCHEME, destination $DESTINATION..."
XCODEBUILD_ARGS=(
	-project "$PROJECT" \
	-scheme "$SCHEME" \
	-destination "$DESTINATION" \
	-derivedDataPath "$DERIVED_DATA_PATH" \
	-parallel-testing-enabled NO \
	test
)

if [[ -n "${IOS_COMPILER_LOG_PATH:-}" ]]; then
	mkdir -p "$(dirname "$IOS_COMPILER_LOG_PATH")"
	xcodebuild "${TOOLCHAIN_ARGS[@]}" "${XCODEBUILD_ARGS[@]}" 2>&1 | tee "$IOS_COMPILER_LOG_PATH"
else
	xcodebuild "${TOOLCHAIN_ARGS[@]}" "${XCODEBUILD_ARGS[@]}" -quiet
fi

echo "iOS XCTest passed for $DESTINATION."
