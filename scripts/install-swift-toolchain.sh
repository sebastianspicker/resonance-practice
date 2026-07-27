#!/usr/bin/env bash
# Install and verify the pinned Swift toolchain required by iOS verification.
set -euo pipefail

SWIFT_VERSION="${SWIFT_VERSION:-6.3.3}"
TOOLCHAIN_NAME="${SWIFT_TOOLCHAIN_NAME:-swift}"
RELEASE_NAME="swift-${SWIFT_VERSION}-RELEASE"
PACKAGE_URL="https://download.swift.org/swift-${SWIFT_VERSION}-release/xcode/${RELEASE_NAME}/${RELEASE_NAME}-osx.pkg"

verify_toolchain() {
	local version_output
	if ! version_output="$(xcrun --toolchain "$TOOLCHAIN_NAME" swift --version 2>/dev/null)"; then
		return 1
	fi
	grep -Fq "Swift version ${SWIFT_VERSION}" <<<"$version_output"
}

if verify_toolchain; then
	echo "Swift ${SWIFT_VERSION} toolchain is already installed."
	exit 0
fi

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/resonance-swift-toolchain.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT
PACKAGE_PATH="$TEMP_DIR/${RELEASE_NAME}-osx.pkg"
SIGNATURE_PATH="$TEMP_DIR/signature.txt"

echo "Downloading Swift ${SWIFT_VERSION} from swift.org..."
curl \
	--fail \
	--location \
	--proto '=https' \
	--tlsv1.2 \
	--output "$PACKAGE_PATH" \
	"$PACKAGE_URL"

pkgutil --check-signature "$PACKAGE_PATH" >"$SIGNATURE_PATH"
if ! grep -Fq "Status: signed by a certificate trusted by Mac OS X" "$SIGNATURE_PATH"; then
	cat "$SIGNATURE_PATH" >&2
	echo "Swift toolchain package did not have a trusted installer signature." >&2
	exit 1
fi

installer -target CurrentUserHomeDirectory -pkg "$PACKAGE_PATH"

if ! verify_toolchain; then
	xcrun --toolchain "$TOOLCHAIN_NAME" swift --version >&2 || true
	echo "Installed Swift toolchain did not report expected version ${SWIFT_VERSION}." >&2
	exit 1
fi

echo "Installed and verified Swift ${SWIFT_VERSION}."
