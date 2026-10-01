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
command -v node >/dev/null || fail "node is required for the iOS source-layer check."
command -v jq >/dev/null || fail "jq is required to select an available iPhone simulator deterministically."
[[ -d "$PROJECT" ]] || fail "native project not found at $PROJECT."
[[ -f "$SCHEME_FILE" ]] || fail "shared scheme not found at $SCHEME_FILE."
find "$APP_DIR/Tests" -name '*.swift' -type f -print -quit | grep -q . || fail "no XCTest source files found under $APP_DIR/Tests."
grep -R -q --include='*.swift' 'func test' "$APP_DIR/Tests" || fail "no XCTest methods found under $APP_DIR/Tests."
node "$ROOT_DIR/scripts/check-ios-layers.mjs" --self-test
node "$ROOT_DIR/scripts/check-ios-layers.mjs"

if [[ -n "${IOS_DESTINATION:-}" ]]; then
	DESTINATION="$IOS_DESTINATION"
else
	SIMULATOR_ID="$(xcrun simctl list devices available -j | jq -r '
		.devices
		| to_entries
		| map(.value[])
		| map(select(
			.isAvailable == true
			and (.deviceTypeIdentifier | contains(".SimDeviceType.iPhone-"))
		))
		| sort_by(.name, .udid)
		| .[0].udid // empty
	')"
	[[ -n "$SIMULATOR_ID" ]] || fail "no available iPhone simulator was found; set IOS_DESTINATION to override."
	DESTINATION="platform=iOS Simulator,id=$SIMULATOR_ID"
fi

TEMP_PATHS=()
remove_temp_paths() {
	if ((${#TEMP_PATHS[@]} > 0)); then
		rm -rf "${TEMP_PATHS[@]}"
	fi
}
trap remove_temp_paths EXIT

if [[ -n "${IOS_DERIVED_DATA_PATH:-}" ]]; then
	[[ -z "${IOS_COMPILER_LOG_PATH:-}" ]] || fail "compiler analysis requires a clean build; omit IOS_DERIVED_DATA_PATH."
	DERIVED_DATA_PATH="$IOS_DERIVED_DATA_PATH"
else
	DERIVED_DATA_PATH="$(mktemp -d "${TMPDIR:-/tmp}/resonance-ios-derived-data.XXXXXX")"
	TEMP_PATHS+=("$DERIVED_DATA_PATH")
fi

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

if [[ -n "${IOS_RESULT_BUNDLE_PATH:-}" ]]; then
	XCODEBUILD_ARGS+=(-resultBundlePath "$IOS_RESULT_BUNDLE_PATH")
fi

if [[ -n "${IOS_COMPILER_LOG_PATH:-}" ]]; then
	mkdir -p "$(dirname "$IOS_COMPILER_LOG_PATH")"
	xcodebuild "${TOOLCHAIN_ARGS[@]}" "${XCODEBUILD_ARGS[@]}" 2>&1 | tee "$IOS_COMPILER_LOG_PATH"
else
	xcodebuild "${TOOLCHAIN_ARGS[@]}" "${XCODEBUILD_ARGS[@]}" -quiet
fi

echo "iOS XCTest passed for $DESTINATION."

# Build-only compiles prove that Release excludes demo and capture code and
# that the screenshot capture configuration still compiles.
build_variant() {
	local label="$1"
	shift
	local variant_derived_data
	variant_derived_data="$(mktemp -d "${TMPDIR:-/tmp}/resonance-ios-build.XXXXXX")"
	TEMP_PATHS+=("$variant_derived_data")
	echo "Building $label for generic/platform=iOS Simulator..."
	xcodebuild "${TOOLCHAIN_ARGS[@]}" \
		-project "$PROJECT" \
		-scheme "$SCHEME" \
		-destination "generic/platform=iOS Simulator" \
		-derivedDataPath "$variant_derived_data" \
		"$@" \
		build \
		-quiet
	echo "$label build passed."
}

build_variant "Release" -configuration Release
build_variant "Debug with RESONANCE_SCREENSHOTS" \
	-configuration Debug \
	'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEBUG RESONANCE_SCREENSHOTS'
