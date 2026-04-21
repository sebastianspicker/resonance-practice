# Release Candidate Screenshot Playbook

## Device Baseline
- Device: iPad (latest available simulator)
- Orientation: Portrait
- Appearance: Dark mode
- Text size: Default

## File Naming Convention
Use:

```text
rc-<version>-<persona>-<screen>-<index>.png
```

Examples:
- `rc-0.1.0-student-courses-01.png`
- `rc-0.1.0-teacher-review-queue-01.png`

## Mandatory Screens

### Student Persona
1. Login page (mock university branding visible)
2. Courses list
3. Entry list (status chips visible)
4. Entry detail (artifact sync phase + feedback section visible)
5. Export view (practice stats visible)
6. Settings view (active host + debug section)
7. Sync Queue view (pending/failed counts)

### Teacher Persona
1. Courses list
2. Teacher review queue (multiple entries visible)
3. Feedback editor (status + snippet chips visible)

## Optional Screens
- Calendar screen (optional; not RC-blocking)
- Entry delete confirmation dialog

## Capture Flow
1. Run `./scripts/demo/capture-ios-screenshots.sh` for the semi-automatic capture flow.
2. Script output folder is `artifacts/screenshots/rc-local` by default (gitignored). Copy final screenshots to `docs/assets/screenshots/rc/` before committing.
3. Optionally override folder via `OUTPUT_DIR=/absolute/path ./scripts/demo/capture-ios-screenshots.sh`.
4. Validate filenames against the naming convention.

## Acceptance Criteria
- No empty placeholder states on mandatory screens.
- Status indicators are readable (`draft/submitted/reviewed`).
- API host/environment text is visible in Settings.
- Queue counters and any errors shown are plausible and non-generic.
- Screenshot filenames follow the naming pattern exactly.
