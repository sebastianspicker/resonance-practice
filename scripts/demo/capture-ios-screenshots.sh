#!/usr/bin/env bash
# Capture a reproducible local Simulator walkthrough and its bounded evidence bundle.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IOS_DIR="$ROOT_DIR/ios/ResonanceApp"
SERVER_DIR="$ROOT_DIR/server"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/artifacts/e2e-walkthrough}"
DERIVED_DATA_DIR="${DERIVED_DATA_DIR:-$ROOT_DIR/.tmp/derived-data-e2e-walkthrough}"
API_PORT="${RESONANCE_WALKTHROUGH_API_PORT:-4100}"
API_BASE="http://127.0.0.1:$API_PORT"
RELEASE_VERSION="${RESONANCE_WALKTHROUGH_RELEASE:-v0.1.0-alpha.1}"
RUNTIME_ID=""
APP_PATH=""
BUNDLE_ID=""
SERVER_PID=""
STUDENT_UDID=""
TEACHER_UDID=""
STUDENT_CREATED=0
TEACHER_CREATED=0
STUDENT_BOOTED_BY_SCRIPT=0
TEACHER_BOOTED_BY_SCRIPT=0
CAPTURE_ROWS="$OUTPUT_DIR/.capture-rows.tsv"
CAPTURE_SETTLE_SECONDS="${RESONANCE_SCREENSHOT_SETTLE_SECONDS:-8}"

require_cmd() {
	command -v "$1" >/dev/null 2>&1 || {
		echo "Missing required command: $1" >&2
		exit 1
	}
}

stop_server() {
	[[ -n "$SERVER_PID" ]] || return
	if kill -0 "$SERVER_PID" >/dev/null 2>&1; then
		kill -TERM "$SERVER_PID" >/dev/null 2>&1 || true
		for _ in {1..20}; do
			kill -0 "$SERVER_PID" >/dev/null 2>&1 || break
			sleep 1
		done
		kill -0 "$SERVER_PID" >/dev/null 2>&1 && kill -KILL "$SERVER_PID" >/dev/null 2>&1 || true
	fi
	wait "$SERVER_PID" >/dev/null 2>&1 || true
	SERVER_PID=""
}

cleanup() {
	local status=$?
	trap - EXIT INT TERM
	stop_server
	if [[ "$STUDENT_BOOTED_BY_SCRIPT" -eq 1 ]]; then xcrun simctl shutdown "$STUDENT_UDID" >/dev/null 2>&1 || true; fi
	if [[ "$TEACHER_BOOTED_BY_SCRIPT" -eq 1 ]]; then xcrun simctl shutdown "$TEACHER_UDID" >/dev/null 2>&1 || true; fi
	if [[ "$STUDENT_CREATED" -eq 1 ]]; then xcrun simctl delete "$STUDENT_UDID" >/dev/null 2>&1 || true; fi
	if [[ "$TEACHER_CREATED" -eq 1 ]]; then xcrun simctl delete "$TEACHER_UDID" >/dev/null 2>&1 || true; fi
	exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for command in xcodebuild xcrun curl npm node docker jq osascript sips; do require_cmd "$command"; done
SOURCE_COMMIT="$(git -C "$ROOT_DIR" rev-parse HEAD)"
if [[ -n "$(git -C "$ROOT_DIR" status --porcelain --untracked-files=all)" ]]; then
	echo "Screenshot capture requires a clean worktree, including untracked files." >&2
	exit 1
fi
mkdir -p "$OUTPUT_DIR" "$ROOT_DIR/.tmp"
find "$OUTPUT_DIR" -maxdepth 1 -type f \( -name '*.png' -o -name 'manifest.json' -o -name 'WALKTHROUGH.md' -o -name 'VERIFICATION_BLOCKED.md' \) -delete
: >"$CAPTURE_ROWS"

if ! docker info >/dev/null 2>&1; then
	echo "Launching Docker Desktop..."
	if ! open -a Docker >/dev/null 2>&1; then
		DOCKER_DESKTOP='/Applications/Docker.app/Contents/MacOS/Docker Desktop.app/Contents/MacOS/Docker Desktop'
		if [[ -x "$DOCKER_DESKTOP" ]]; then
			"$DOCKER_DESKTOP" >/dev/null 2>&1 &
		else
			echo "Docker Desktop could not be launched." >&2
			exit 1
		fi
	fi
	for _ in {1..60}; do
		docker info >/dev/null 2>&1 && break
		sleep 2
	done
fi
docker info >/dev/null 2>&1 || { echo "Docker Desktop did not become ready." >&2; exit 1; }

echo "[1/7] Validating fixtures and bootstrapping dedicated local services"
DATABASE_URL='postgresql://resonance:resonance@127.0.0.1:5432/resonance' \
	"$ROOT_DIR/scripts/demo/bootstrap-local-demo.sh"
if curl -fsS "$API_BASE/health" >/dev/null 2>&1; then
	echo "Refusing to reuse a process already listening at $API_BASE." >&2
	exit 1
fi
(
	# Run outside server/ so dotenv cannot discover server/.env files. Every
	# value used by this loopback-only process is declared below.
	cd "$OUTPUT_DIR"
	export PORT="$API_PORT"
	export HOST='127.0.0.1'
	export DATABASE_URL='postgresql://resonance:resonance@127.0.0.1:5432/resonance'
	export AUTH_MODE='dev'
	export JWT_SECRET='walkthrough-only-loopback-jwt-secret-000000000000'
	export JWT_REFRESH_SECRET='walkthrough-only-loopback-refresh-secret-00000000'
	export DEV_UNIVERSITY_NAME='Mock University Conservatory'
	export DEV_LOGIN_CALLBACK_URL='resonance://auth-callback'
	export S3_ENDPOINT='http://127.0.0.1:9000'
	export S3_REGION='us-east-1'
	export S3_BUCKET='resonance-dev'
	export S3_ACCESS_KEY='minioadmin'
	export S3_SECRET_KEY='minioadmin'
	export S3_FORCE_PATH_STYLE='true'
	export CORS_ORIGINS='http://127.0.0.1'
	exec "$SERVER_DIR/node_modules/.bin/tsx" "$SERVER_DIR/src/index.ts"
) >"$OUTPUT_DIR/api.log" 2>&1 &
SERVER_PID=$!
for _ in {1..60}; do
	curl -fsS "$API_BASE/ready" >/dev/null 2>&1 && break
	sleep 1
done
if ! curl -fsS "$API_BASE/ready" >/dev/null 2>&1; then
	cat "$OUTPUT_DIR/api.log" >&2
	exit 1
fi

echo "[2/7] Creating dedicated student and teacher Simulators"
RUNTIME_ID="$(xcrun simctl list runtimes available -j | jq -r '[.runtimes[] | select(.platform == "iOS" and .isAvailable)] | sort_by(.version) | last.identifier // empty')"
[[ -n "$RUNTIME_ID" ]] || { echo "No available iOS Simulator runtime." >&2; exit 1; }

resolve_device_type() {
	local prefix="$1"
	xcrun simctl list devicetypes -j | jq -r --arg prefix "$prefix" '[.devicetypes[] | select(.name | startswith($prefix))] | last.identifier // empty'
}

ensure_device() {
	local name="$1" type_id="$2" result_var="$3" created_var="$4" booted_var="$5"
	local udid state
	udid="$(xcrun simctl list devices available -j | jq -r --arg name "$name" --arg runtime "$RUNTIME_ID" '[.devices[$runtime][]? | select(.name == $name)] | first.udid // empty')"
	if [[ -z "$udid" ]]; then
		udid="$(xcrun simctl create "$name" "$type_id" "$RUNTIME_ID")"
		printf -v "$created_var" '%s' 1
	fi
	state="$(xcrun simctl list devices -j | jq -r --arg udid "$udid" '.devices[][] | select(.udid == $udid) | .state')"
	if [[ "$state" != "Booted" ]]; then
		xcrun simctl boot "$udid"
		printf -v "$booted_var" '%s' 1
	fi
	xcrun simctl bootstatus "$udid" -b
	printf -v "$result_var" '%s' "$udid"
}

IPHONE_TYPE="$(resolve_device_type 'iPhone 16')"
IPAD_TYPE="$(resolve_device_type 'iPad Pro 11-inch')"
if [[ -z "$IPHONE_TYPE" ]]; then IPHONE_TYPE="$(resolve_device_type 'iPhone')"; fi
if [[ -z "$IPAD_TYPE" ]]; then IPAD_TYPE="$(resolve_device_type 'iPad')"; fi
[[ -n "$IPHONE_TYPE" && -n "$IPAD_TYPE" ]] || { echo "Required iPhone/iPad device types are unavailable." >&2; exit 1; }
ensure_device 'Resonance Walkthrough Student' "$IPHONE_TYPE" STUDENT_UDID STUDENT_CREATED STUDENT_BOOTED_BY_SCRIPT
ensure_device 'Resonance Walkthrough Teacher' "$IPAD_TYPE" TEACHER_UDID TEACHER_CREATED TEACHER_BOOTED_BY_SCRIPT

SIMULATOR_APP="$(xcode-select -p)/Applications/Simulator.app"
open "$SIMULATOR_APP" >/dev/null 2>&1 || true

xcrun simctl ui "$STUDENT_UDID" appearance light
xcrun simctl ui "$STUDENT_UDID" content_size medium
xcrun simctl ui "$TEACHER_UDID" appearance dark
xcrun simctl ui "$TEACHER_UDID" content_size medium

echo "[3/7] Building and installing the debug app"
rm -rf "$DERIVED_DATA_DIR"
xcodebuild -project "$IOS_DIR/ResonanceApp.xcodeproj" -scheme ResonanceApp -configuration Debug \
	-destination "id=$STUDENT_UDID" -derivedDataPath "$DERIVED_DATA_DIR" \
	ENABLE_USER_SCRIPT_SANDBOXING=NO OTHER_SWIFT_FLAGS='-Xfrontend -disable-sandbox' \
	SWIFT_ACTIVE_COMPILATION_CONDITIONS=RESONANCE_SCREENSHOTS \
	build >"$OUTPUT_DIR/xcodebuild.log"
APP_PATH="$(find "$DERIVED_DATA_DIR/Build/Products" -maxdepth 2 -name 'ResonanceApp.app' -print -quit)"
[[ -d "$APP_PATH" ]] || { echo "Built app bundle was not found." >&2; exit 1; }
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Info.plist")"
for udid in "$STUDENT_UDID" "$TEACHER_UDID"; do
	xcrun simctl uninstall "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
	xcrun simctl install "$udid" "$APP_PATH"
done

capture() {
	local index="$1" persona="$2" screen="$3" title="$4" udid="$5" appearance="$6" device="$7"
	local file_slug="${8:-$screen}" filename
	filename="$(printf '%02d' "$index")-${persona}-${file_slug}.png"
	local target="$OUTPUT_DIR/$filename"
	echo "  Capturing $filename"
	SIMCTL_CHILD_RESONANCE_SCREENSHOT_MODE=1 \
		SIMCTL_CHILD_RESONANCE_SCREENSHOT_ROLE="$persona" \
		SIMCTL_CHILD_RESONANCE_SCREENSHOT_SCREEN="$screen" \
		SIMCTL_CHILD_RESONANCE_API_BASE="$API_BASE" \
	SIMCTL_CHILD_RESONANCE_DEMO_UNIVERSITY_NAME='Mock University Conservatory' \
		xcrun simctl launch --terminate-running-process "$udid" "$BUNDLE_ID" >/dev/null
	sleep "$CAPTURE_SETTLE_SECONDS"
	xcrun simctl io "$udid" screenshot "$target" >/dev/null
	if [[ "$device" == *" landscape" ]]; then
		local normalized="$target.normalized.png"
		sips --rotate 90 "$target" --out "$normalized" >/dev/null
		mv "$normalized" "$target"
	fi
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$index" "$filename" "$persona" "$screen" "$title" "$device" "$appearance" >>"$CAPTURE_ROWS"
}

rotate_teacher_landscape() {
	open "$SIMULATOR_APP" --args -CurrentDeviceUDID "$TEACHER_UDID" >/dev/null 2>&1 || true
	osascript \
		-e 'tell application "Simulator" to activate' \
		-e 'delay 1' \
		-e 'tell application "System Events" to key code 124 using command down'
	sleep 2
}

echo "[4/7] Capturing the 12-step walkthrough"
capture 1 student login 'Student sign-in' "$STUDENT_UDID" light 'iPhone portrait'
capture 2 student courses 'Student course selection' "$STUDENT_UDID" light 'iPhone portrait'
capture 3 student entry-list 'Draft, submitted, and reviewed entries' "$STUDENT_UDID" light 'iPhone portrait'
capture 4 student new-entry 'Prefilled new-entry form' "$STUDENT_UDID" light 'iPhone portrait'
capture 5 student entry-detail 'Draft capture and submission controls' "$STUDENT_UDID" light 'iPhone portrait'
capture 6 student queue 'Pending and failed sync work' "$STUDENT_UDID" light 'iPhone portrait'
rotate_teacher_landscape
capture 7 teacher courses 'Teacher course selection' "$TEACHER_UDID" dark 'iPad landscape'
capture 8 teacher teacher-review-queue 'Teacher review queue' "$TEACHER_UDID" dark 'iPad landscape' review-queue
capture 9 teacher submission-detail 'Submission media and feedback composer' "$TEACHER_UDID" dark 'iPad landscape'
capture 10 teacher feedback-editor 'Timestamped feedback draft' "$TEACHER_UDID" dark 'iPad landscape'
capture 11 teacher feedback-queued 'Feedback queued state' "$TEACHER_UDID" dark 'iPad landscape'
capture 12 student reviewed-feedback 'Reviewed entry feedback and markers' "$STUDENT_UDID" light 'iPhone portrait'

echo "[5/7] Validating capture set and generating manifest"
RUNTIME_NAME="$(xcrun simctl list runtimes available -j | jq -r --arg id "$RUNTIME_ID" '.runtimes[] | select(.identifier == $id) | .name')"
node --input-type=module - "$OUTPUT_DIR" "$CAPTURE_ROWS" "$SOURCE_COMMIT" "$RUNTIME_NAME" "$RELEASE_VERSION" <<'NODE'
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const [outputDir, rowsPath, sourceCommit, runtimeName, release] = process.argv.slice(2);
if (!/^v\d+\.\d+\.\d+-alpha\.\d+$/.test(release)) {
  throw new Error(`Invalid alpha release identifier: ${release}`);
}
const rows = readFileSync(rowsPath, 'utf8').trim().split('\n').filter(Boolean);
if (rows.length !== 12) throw new Error(`Expected 12 capture rows, found ${rows.length}`);
const runtimeVersion = runtimeName.replace(/^iOS\s+/, '');
if (runtimeVersion === runtimeName) {
  throw new Error(`Expected an iOS Simulator runtime name, found ${runtimeName}`);
}
const hashes = new Set();
const captures = rows.map((row) => {
  const [index, file, persona, screen, title, device, appearance] = row.split('\t');
  const data = readFileSync(join(outputDir, file));
  if (data.length < 10_000 || data.toString('hex', 0, 8) !== '89504e470d0a1a0a') {
    throw new Error(`${file} is blank, truncated, or not a PNG`);
  }
  const width = data.readUInt32BE(16);
  const height = data.readUInt32BE(20);
  const orientation = device.endsWith('landscape') ? 'landscape' : 'portrait';
  if (orientation === 'portrait' && height <= width) {
    throw new Error(`${file} is not portrait (${width}x${height})`);
  }
  if (orientation === 'landscape' && width <= height) {
    throw new Error(`${file} is not landscape (${width}x${height})`);
  }
  const sha256 = createHash('sha256').update(data).digest('hex');
  if (hashes.has(sha256)) throw new Error(`${file} duplicates another screenshot`);
  hashes.add(sha256);
  const platform = device.startsWith('iPad') ? 'iPadOS' : 'iOS';
  return {
    index: Number(index), file, persona, screen, title, evidenceKind: 'visual-ui-evidence',
    device, os: `${platform} ${runtimeVersion}`, orientation, appearance, textSize: 'medium',
    width, height, sha256, verified: { png: true, orientation: true, unique: true },
  };
});
const manifest = {
  schemaVersion: 2,
  release,
  generatedAt: new Date().toISOString(),
  revalidatedAt: new Date().toISOString(),
  source: {
    commit: sourceCommit,
    dirty: false,
    status: 'captured-clean-commit',
  },
  proofModel: {
    kind: 'visual-ui-evidence',
    description: 'Deterministic debug-only Simulator scenarios. Screenshots do not prove networking or interaction.',
  },
  verification: {
    fixtureValidator: 'passed', apiReadiness: 'passed', iosDebugBuild: 'passed',
    screenshotCount: 12, screenshotSet: 'integrity-verified', humanVisualInspection: 'pending',
    serviceE2E: 'not run by capture harness; a separate passing service gate is required before measured claims are accepted',
    captureLogsPublished: false,
    releaseReady: false,
  },
  captures,
};
writeFileSync(join(outputDir, 'manifest.json'), `${JSON.stringify(manifest, null, 2)}\n`);
NODE

echo "[6/7] Writing walkthrough"
node --input-type=module - "$OUTPUT_DIR" <<'NODE'
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
const dir = process.argv[2];
const manifest = JSON.parse(readFileSync(join(dir, 'manifest.json'), 'utf8'));
const measured = new Map([
  [1, 'Measured E2E coverage target: dev authentication and token exchange. Requires the separate service gate to pass.'],
  [2, 'Measured E2E coverage target: authenticated student and teacher course membership. Requires the separate service gate to pass.'],
  [3, 'Measured E2E coverage target: draft creation, submission, review transition, and reviewed retrieval. Requires the separate service gate to pass.'],
  [5, 'Measured E2E coverage target: artifact creation, object upload, confirmation, and submission. Requires the separate service gate to pass.'],
  [7, 'Measured E2E coverage target: same-course teacher authorization. Requires the separate service gate to pass.'],
  [8, 'Measured E2E coverage target: submitted entries appear in the teacher review queue. Requires the separate service gate to pass.'],
  [9, 'Measured E2E coverage target: teacher receives an authorized download URL and retrieves exact uploaded bytes. Requires the separate service gate to pass.'],
  [10, 'Measured E2E coverage target: feedback comments and timestamped markers are persisted. Requires the separate service gate to pass.'],
  [12, 'Measured E2E coverage target: student retrieves teacher comments, marker time/text, and reviewed state. Requires the separate service gate to pass.'],
]);
const visualOnly = new Map([
  [4, 'Visual only: deterministic form composition; no save interaction is claimed.'],
  [6, 'Visual only: deterministic pending/failed queue and recovery copy.'],
  [11, 'Visual only: deterministic local Feedback queued indicator.'],
]);
const sections = manifest.captures.map((capture) => `## ${capture.index}. ${capture.title}\n\n![${capture.title}](./${capture.file})\n\n${measured.get(capture.index) ?? visualOnly.get(capture.index)}\n`);
const markdown = `# Resonance hybrid E2E walkthrough\n\nThis local evidence bundle deliberately separates measured service behavior from deterministic Simulator UI evidence. Screenshots narrate the workflow; they do not independently prove taps, networking, upload, authorization, or persistence. The process-level E2E is the intended proof source, and its claims are accepted only after that separate gate passes.\n\n${sections.join('\n')}\n## Verification boundary\n\nSee \`manifest.json\` for device/OS/appearance/text-size metadata, dimensions, SHA-256 checksums, source state, and capture validation. Human visual inspection and repository gates are recorded in the final handoff after capture.\n`;
writeFileSync(join(dir, 'WALKTHROUGH.md'), markdown);
NODE

rm -f "$CAPTURE_ROWS"
echo "[7/7] Walkthrough bundle ready at $OUTPUT_DIR"
