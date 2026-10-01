#!/usr/bin/env bash
# Enforces the source-level boundary: Core may not depend on app composition or demo policy.
set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$APP_DIR/Sources/Core"
FORBIDDEN='\b(AppConfig|ScreenshotScenario|ScreenshotPersona|AppDemoDependencyFactory|DemoConfiguration)\b'

if matches="$(rg -n --glob '*.swift' "$FORBIDDEN" "$CORE_DIR")"; then
	echo "Core layering violation: Core may not reference App or demo-only symbols." >&2
	echo "$matches" >&2
	exit 1
fi

echo "Core layering check passed."
