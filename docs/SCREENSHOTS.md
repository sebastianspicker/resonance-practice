# Screenshot Evidence

Screenshots are supporting visual evidence. They do not prove taps, networking, authorization, persistence, accessibility, localization, signing, or deployment.

## Approved alpha set

The `v0.1.0-alpha.1` set contains 12 deterministic Simulator captures:

- student on iPhone in light appearance;
- teacher on iPad in dark appearance;
- sign-in, course selection, evidence status, draft entry, entry detail, sync queue, review queue, submission detail, feedback editing, queued feedback, and reviewed feedback;
- English mock identities and mock course content only.

Browse the [complete walkthrough](./ALPHA_WALKTHROUGH.md) or inspect the [sanitized capture manifest](./assets/screenshots/approved/v0.1.0-alpha.1/manifest.json). The manifest records the clean source commit, OS, appearance, dimensions, and SHA-256 checksum for every PNG. Capture logs are not published.

## Promotion policy

1. Capture from a clean code-freeze commit after the full local gate passes.
2. Keep unreviewed output in `artifacts/e2e-walkthrough/` or `docs/assets/screenshots/local/`; both are ignored.
3. Inspect every image for clipping, role correctness, debug content, private data, empty frames, and misleading state.
4. Validate count, filename, PNG signature, dimensions, uniqueness, and manifest checksums.
5. Publish only reviewed PNGs plus sanitized metadata under `docs/assets/screenshots/approved/<version>/`.
6. Give every Markdown image descriptive alt text and link the versioned set from its release notes.

Do not publish API logs, Xcode logs, derived data, Simulator identifiers, local filesystem paths, real identities, tokens, private recordings, or unredacted diagnostics.

## Current evidence boundary

The approved alpha images exercise a deliberately small matrix: iPhone/iPad, student/teacher, light/dark, portrait, English, and medium text size. They include iPadOS 26 system window chrome where shown.

The following remain open and must not be inferred from the gallery:

- complete German localization and locale-specific layout review;
- landscape and resizable iPad window coverage;
- large and accessibility Dynamic Type sizes;
- VoiceOver, Voice Control, Switch Control, and keyboard traversal;
- Bold Text, Increase Contrast, Reduce Motion, and Reduce Transparency;
- permission, offline recovery, stale data, and destructive-account flows;
- signed builds, TestFlight, real identity/storage services, and production deployment.

## Visual acceptance criteria

- Critical content is not clipped, hidden, or overlapped.
- Status remains understandable without relying on color alone.
- Roles and selected course context match the narrated flow.
- Long mock content exercises wrapping without presenting real data.
- Empty, loading, error, permission, and queued states are labeled honestly.
- Any system chrome is recognizable and not described as app behavior.
