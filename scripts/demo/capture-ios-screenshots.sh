#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IOS_DIR="$ROOT_DIR/ios/ResonanceApp"
SERVER_DIR="$ROOT_DIR/server"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/artifacts/screenshots/rc-local}"
DERIVED_DATA_DIR="${DERIVED_DATA_DIR:-$ROOT_DIR/.tmp/derived-data-rc-screenshots}"
RC_VERSION="${RC_VERSION:-0.1.0-rc}"
DEVICE_NAME="${IOS_SIM_DEVICE_NAME:-Resonance RC iPad}"
DEVICE_TYPE="${IOS_SIM_DEVICE_TYPE:-iPad Pro 11-inch (M5)}"
API_BASE="${RESONANCE_API_BASE:-http://localhost:4000}"
DEMO_UNIVERSITY_NAME="${RESONANCE_DEMO_UNIVERSITY_NAME:-Mock University Conservatory}"

SERVER_PID=""

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

cleanup() {
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

require_cmd xcodebuild
require_cmd xcrun
require_cmd curl
require_cmd npm
require_cmd node
require_cmd docker

mkdir -p "$OUTPUT_DIR" "$ROOT_DIR/.tmp"

echo "[1/8] Bootstrapping local demo backend + seed"
"$ROOT_DIR/scripts/demo/bootstrap-local-demo.sh"

if ! curl -fsS "$API_BASE/health" >/dev/null 2>&1; then
  echo "[2/8] Starting API server in background"
  (
    cd "$SERVER_DIR"
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -z "$line" || "$line" == \#* ]] && continue
      key="${line%%=*}"
      value="${line#*=}"
      export "$key=$value"
    done < ".env.example"
    npm run dev
  ) >"$ROOT_DIR/.tmp/rc-demo-api.log" 2>&1 &
  SERVER_PID=$!

  for _ in {1..60}; do
    if curl -fsS "$API_BASE/health" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
fi

if ! curl -fsS "$API_BASE/health" >/dev/null 2>&1; then
  echo "API not reachable at $API_BASE" >&2
  exit 1
fi

echo "[3/8] Resolving simulator runtime and device"
RUNTIME_ID="$(
  xcrun simctl list runtimes available | awk '/iOS/ { gsub(/[()]/, "", $NF); print $NF }' | tail -n 1
)"
if [[ -z "$RUNTIME_ID" ]]; then
  echo "No available iOS simulator runtime found. Install one in Xcode Settings > Platforms." >&2
  exit 1
fi

DEVICE_TYPE_ID="$(
  xcrun simctl list devicetypes | awk -v wanted="$DEVICE_TYPE" '$0 ~ wanted { gsub(/[()]/, "", $NF); print $NF }' | head -n 1
)"
if [[ -z "$DEVICE_TYPE_ID" ]]; then
  DEVICE_TYPE_ID="$(
    xcrun simctl list devicetypes | awk '/iPad/ { gsub(/[()]/, "", $NF); print $NF }' | head -n 1
  )"
fi
if [[ -z "$DEVICE_TYPE_ID" ]]; then
  echo "Simulator iPad device type not found." >&2
  exit 1
fi

UDID="$(
  xcrun simctl list devices available | awk -v wanted="$DEVICE_NAME" '$0 ~ wanted { gsub(/[()]/, "", $(NF-1)); print $(NF-1) }' | head -n 1
)"

if [[ -z "$UDID" ]]; then
  UDID="$(xcrun simctl create "$DEVICE_NAME" "$DEVICE_TYPE_ID" "$RUNTIME_ID")"
fi

echo "[4/8] Booting simulator ($UDID)"
xcrun simctl boot "$UDID" >/dev/null 2>&1 || true
open -a Simulator --args -CurrentDeviceUDID "$UDID" >/dev/null 2>&1 || true
for _ in {1..60}; do
  if xcrun simctl list devices | grep -q "$UDID.*(Booted)"; then
    break
  fi
  sleep 1
done
if ! xcrun simctl list devices | grep -q "$UDID.*(Booted)"; then
  echo "Simulator failed to reach Booted state: $UDID" >&2
  exit 1
fi
xcrun simctl ui "$UDID" appearance dark || true
xcrun simctl ui "$UDID" content_size large || true

echo "[5/8] Building iOS app"
rm -rf "$DERIVED_DATA_DIR"
cd "$IOS_DIR"
xcodebuild \
  -scheme ResonanceApp \
  -configuration Debug \
  -destination "id=$UDID" \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  build >/tmp/resonance-ios-build.log

APP_PATH="$(find "$DERIVED_DATA_DIR/Build/Products" -maxdepth 2 -name 'ResonanceApp.app' | head -n 1)"
if [[ -z "$APP_PATH" ]]; then
  PRODUCTS_DIR="$DERIVED_DATA_DIR/Build/Products/Debug-iphonesimulator"
  BIN_PATH="$PRODUCTS_DIR/ResonanceApp"
  RESOURCE_JSON="$PRODUCTS_DIR/ResonanceApp_ResonanceApp.bundle/mock-university.json"
  APP_PATH="$PRODUCTS_DIR/ResonanceApp.app"

  if [[ ! -f "$BIN_PATH" ]]; then
    echo "Could not find built app bundle or binary in $DERIVED_DATA_DIR/Build/Products" >&2
    exit 1
  fi

  echo "No .app bundle produced by SwiftPM; creating wrapper app bundle."
  rm -rf "$APP_PATH"
  mkdir -p "$APP_PATH"
  cp "$BIN_PATH" "$APP_PATH/ResonanceApp"
  chmod +x "$APP_PATH/ResonanceApp"
  if [[ -f "$RESOURCE_JSON" ]]; then
    cp "$RESOURCE_JSON" "$APP_PATH/mock-university.json"
  fi

  cat > "$APP_PATH/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>ResonanceApp</string>
  <key>CFBundleIdentifier</key><string>edu.university.resonance</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>ResonanceApp</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSRequiresIPhoneOS</key><true/>
  <key>UIRequiresFullScreen</key><true/>
  <key>UISupportedInterfaceOrientations</key>
  <array>
    <string>UIInterfaceOrientationPortrait</string>
    <string>UIInterfaceOrientationPortraitUpsideDown</string>
  </array>
  <key>UISupportedInterfaceOrientations~ipad</key>
  <array>
    <string>UIInterfaceOrientationPortrait</string>
    <string>UIInterfaceOrientationPortraitUpsideDown</string>
  </array>
</dict>
</plist>
PLIST

  codesign --force --sign - "$APP_PATH" >/dev/null 2>&1 || true
fi

# Enforce deterministic fullscreen + portrait captures.
PLIST_PATH="$APP_PATH/Info.plist"
if [[ -f "$PLIST_PATH" ]]; then
  /usr/libexec/PlistBuddy -c "Set :UIRequiresFullScreen true" "$PLIST_PATH" >/dev/null 2>&1 || \
    /usr/libexec/PlistBuddy -c "Add :UIRequiresFullScreen bool true" "$PLIST_PATH"

  /usr/libexec/PlistBuddy -c "Delete :UISupportedInterfaceOrientations" "$PLIST_PATH" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy -c "Add :UISupportedInterfaceOrientations array" "$PLIST_PATH"
  /usr/libexec/PlistBuddy -c "Add :UISupportedInterfaceOrientations:0 string UIInterfaceOrientationPortrait" "$PLIST_PATH"
  /usr/libexec/PlistBuddy -c "Add :UISupportedInterfaceOrientations:1 string UIInterfaceOrientationPortraitUpsideDown" "$PLIST_PATH"

  /usr/libexec/PlistBuddy -c "Delete :UISupportedInterfaceOrientations~ipad" "$PLIST_PATH" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy -c "Add :UISupportedInterfaceOrientations~ipad array" "$PLIST_PATH"
  /usr/libexec/PlistBuddy -c "Add :UISupportedInterfaceOrientations~ipad:0 string UIInterfaceOrientationPortrait" "$PLIST_PATH"
  /usr/libexec/PlistBuddy -c "Add :UISupportedInterfaceOrientations~ipad:1 string UIInterfaceOrientationPortraitUpsideDown" "$PLIST_PATH"

  codesign --force --sign - "$APP_PATH" >/dev/null 2>&1 || true
fi

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Info.plist")"

echo "[6/8] Installing app ($BUNDLE_ID)"
xcrun simctl uninstall "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl install "$UDID" "$APP_PATH"

capture() {
  local persona="$1"
  local screen="$2"
  local index="$3"
  local wait_seconds="$4"
  local target="$OUTPUT_DIR/rc-${RC_VERSION}-${persona}-${screen}-${index}.png"

  echo " - Capturing $persona / $screen -> $(basename "$target")"

  SIMCTL_CHILD_RESONANCE_SCREENSHOT_MODE=1 \
  SIMCTL_CHILD_RESONANCE_SCREENSHOT_ROLE="$persona" \
  SIMCTL_CHILD_RESONANCE_SCREENSHOT_SCREEN="$screen" \
  SIMCTL_CHILD_RESONANCE_API_BASE="$API_BASE" \
  SIMCTL_CHILD_RESONANCE_DEMO_UNIVERSITY_NAME="$DEMO_UNIVERSITY_NAME" \
    xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE_ID" >/dev/null

  sleep "$wait_seconds"
  xcrun simctl io "$UDID" screenshot "$target" >/dev/null
}

echo "[7/8] Capturing mandatory RC screenshots"
capture "student" "login" "01" "2"
capture "student" "courses" "01" "4"
capture "student" "entry-list" "01" "4"
capture "student" "entry-detail" "01" "4"
capture "student" "export" "01" "4"
capture "student" "settings" "01" "4"
capture "student" "queue" "01" "4"
capture "teacher" "courses" "01" "4"
capture "teacher" "teacher-review-queue" "01" "6"
capture "teacher" "feedback-editor" "01" "4"

echo "[8/8] Done"
echo "Screenshots written to: $OUTPUT_DIR"
ls -1 "$OUTPUT_DIR" | sed 's/^/ - /'
