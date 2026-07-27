# Screenshot Evidence

Screenshots are supporting visual evidence. They do not prove taps, networking, authorization, persistence, accessibility, localization, signing, or deployment.

## Required final capture

`v0.1.0-alpha.1` has no approved public screenshot set. Historical assets have
unresolved commit provenance and visible clipping, so they must not be linked
or used as release evidence. Capture and review exactly the 12 scenarios in
the [alpha walkthrough](./ALPHA_WALKTHROUGH.md) from a clean source-freeze
commit.

## Capture and promotion policy

1. Capture from a clean source-freeze commit after all required local gates pass.
2. Keep unreviewed output in `artifacts/e2e-walkthrough/` or `docs/assets/screenshots/local/`; both are ignored.
3. Inspect every image for clipping, role correctness, debug content, private data, empty frames, and misleading state.
4. Validate count, filename, PNG signature, dimensions, uniqueness, and manifest checksums.
5. Publish only reviewed PNGs plus sanitized metadata under `docs/assets/screenshots/approved/<version>/`.
6. Record the source-freeze capture commit, device and OS metadata, dimensions,
   filenames, and SHA-256 checksums in a sanitized manifest. The iPhone rows
   must use `iOS <version>` and the iPad rows must use `iPadOS <version>`.
7. Add descriptive alt text only after the images and manifest have passed
   review; link the versioned set from the release notes.

Promotion is a separate commit after capture. The capture manifest records
`source.status: "captured-clean-commit"`,
`verification.humanVisualInspection: "pending"`, and
`verification.releaseReady: false`. Reviewers change exactly those fields to
`"release-ready"`, `"passed"`, and `true` when they promote it. The approved
manifest must name the source-freeze commit as `source.commit`; that commit
must resolve and be an ancestor of the publication commit. Only approved PNGs,
the manifest, `SCREENSHOTS.md`, `ALPHA_WALKTHROUGH.md`, `RELEASING.md`, and the
matching `docs/release-notes/<release>.md` may change between them. Every
approved PNG needs a public Markdown image reference with nonempty alt text.
After human review, validate the publication commit with
`node scripts/validate-public-docs.mjs --release`. Default validation is
intentionally source-only and allows no approved manifest before screenshots
exist.

Do not publish API logs, Xcode logs, derived data, Simulator identifiers, local filesystem paths, real identities, tokens, private recordings, or unredacted diagnostics.

## Evidence boundary

Future screenshots will be visual evidence only. They will not prove taps,
networking, authorization, persistence, accessibility, localization, signing,
or deployment. The following remain open and must not be inferred from the
capture set:

- complete German localization and locale-specific layout review;
- portrait and resizable iPad window coverage;
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
