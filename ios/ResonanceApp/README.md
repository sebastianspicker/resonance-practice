# Resonance iOS app

The iOS component is the offline-first SwiftUI client for students and teachers.
It owns local practice entries, protected media, authentication, course and
review interfaces, PDF export, and the durable synchronization outbox.

## Requirements

- iOS or iPadOS 17 or later
- macOS with Xcode, `xcrun`, and `xcodebuild`
- `jq` and an available iPhone Simulator for repository verification
- SwiftLint 0.63.2 for strict source linting

The tracked Xcode project and shared `ResonanceApp` scheme are the supported
build and test entry points, and the only build definition. The project uses
folder-synchronized groups: every file under `Sources/` belongs to the app
target and every file under `Tests/` to the test target, so adding, moving, or
removing a file needs no project edit. `Sources/Resources/Info.plist` is
excluded from bundle resources because the target reads it via
`INFOPLIST_FILE`.

## Run

Start the local server as described in [Development](../../docs/DEVELOPMENT.md),
then open `ResonanceApp.xcodeproj` and run the shared `ResonanceApp` scheme. The
target supports iPhone and iPad and has code signing disabled in the repository
configuration.

The client uses `http://localhost:4000` by default. Set `RESONANCE_API_BASE` in
the Xcode scheme environment to use another credential-free HTTP(S) origin.
Values with credentials, query text, or fragments are rejected, and API v1 paths
stay absolute even when the configured base has a path.

The native callback is `resonance://auth-callback`, and the server's
`APP_AUTH_REDIRECT_URI` must match it exactly.

## Source organization

| Path | Responsibility |
| --- | --- |
| `Sources/App/` | SwiftUI composition, app state, navigation, and demo and screenshot wiring |
| `Sources/Core/` | Domain values, SwiftData persistence, networking, security, media, calendar, export, feedback, and synchronization |
| `Sources/Features/` | Authentication, capture, courses, entries, export, feedback, review, settings, and sync-status flows |
| `Sources/SharedUI/` | Reusable theme tokens and presentation primitives |

Core depends on nothing above it, SharedUI may use Core, Features may use Core
and SharedUI, and App assembles the feature and service graph. Features read the
services App provides from the SwiftUI environment (`ErrorReporter`,
`\.apiClient`, `\.capturePresentation`) instead of referencing App types.
`node scripts/check-ios-layers.mjs` enforces these rules from type
declarations; both repository verifiers run it.

The outbox stores typed, versioned commands bound to the authenticated local
owner. `SyncManager` sends ready commands in FIFO order in batches of at most 25
and preserves operation IDs, optimistic versions, retries, and conflict
recovery. Media upload follows its separate create-session, signed `PUT`, and
completion flow.

Read [Architecture](../../docs/ARCHITECTURE.md) and [API](../../docs/API.md)
before changing these boundaries.

## Build, test, and lint

Run from the repository root:

```bash
./scripts/verify-ios.sh
./scripts/lint-swift.sh lint
```

The verifier selects an available iPhone Simulator unless `IOS_DESTINATION` is
set, creates temporary DerivedData, runs the source-layer check, and executes
XCTest through the shared scheme. It then compiles a Release build and a Debug
build with `RESONANCE_SCREENSHOTS` for a generic simulator. It also accepts
`IOS_TOOLCHAIN`, `IOS_EXPECTED_SWIFT_VERSION`,
`IOS_RESULT_BUNDLE_PATH`, and `IOS_DERIVED_DATA_PATH`.

## Demo data and screenshot capture

Debug builds offer Settings > Debug > Load Mock Demo Data, which loads the
bundled mock-university fixture. Release builds compile the demo-data loader out.

Screenshot capture code compiles only when the `RESONANCE_SCREENSHOTS`
compilation condition is set, for example:

```bash
xcodebuild -project ios/ResonanceApp/ResonanceApp.xcodeproj -scheme ResonanceApp \
  -destination 'generic/platform=iOS Simulator' \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEBUG RESONANCE_SCREENSHOTS' build
```

A capture build reads these launch environment variables; other builds ignore
them:

| Variable | Meaning |
| --- | --- |
| `RESONANCE_SCREENSHOT_MODE` | `1` enables a capture scenario with an in-memory store and a fake local session |
| `RESONANCE_SCREENSHOT_ROLE` | `student` (default) or `teacher` |
| `RESONANCE_SCREENSHOT_SCREEN` | Route such as `courses` (default), `new-entry`, `entry-detail`, `practice-review`, `teacher-review-queue`, or `feedback-editor`; see `ScreenshotScreen` for the full list |
| `RESONANCE_SCREENSHOT_STUDENT_USER_ID`, `RESONANCE_SCREENSHOT_TEACHER_USER_ID`, `RESONANCE_SCREENSHOT_PRIMARY_COURSE_ID` | Optional fixture ID overrides |

`RESONANCE_DEMO_UNIVERSITY_NAME` overrides the university name on the sign-in
screen in every build.

The full local CI lane additionally runs SwiftLint analysis against the compiler
log and verifies with the exact Swift 6.3.3 toolchain.

## Generated and local files

Do not commit SwiftPM output, DerivedData, user workspace state, result bundles,
compiler logs, or local screenshots.

`Tests/NetworkingContracts/APIClientSyncCommandTests.swift` contains a marked
projection generated from `../../contracts/v1-api-contract.json`. Do not edit
that region directly. After an intentional contract change, update it from the
repository root:

```bash
node scripts/generate-v1-contract-projection.mjs --write
```

## Interface constraints

Use native SwiftUI navigation, lists, forms, toolbars, and accessibility
behavior. Keep lifecycle and privacy state legible without relying on color
alone, and preserve Dynamic Type, VoiceOver, keyboard, contrast, and Reduce
Motion behavior. Workflow-specific UI belongs in Features, and generic controls
and tokens belong in SharedUI. See [Design](../../DESIGN.md).
