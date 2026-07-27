# Design System

## Direction

The Atelier direction uses restrained, cool surfaces for practice evidence and
private teacher feedback. Evidence takes visual priority, lifecycle state is
written explicitly, and Resonance violet is the primary action accent.

## Theme

Follow the system light and dark appearances. Never force an appearance.
Workspace surfaces use cool violet-adjacent neutrals (not cream or sand).

## Color

- Primary action: Resonance violet `#5E3FC4` with white text (dark: `#B7A8FF`).
- Accent strong: `#4F35AD` (dark: `#C8BCFF`).
- Soft selection: `#F0EDFF` (dark: `#26213A`).
- Workspace paper: `#F3F2F7` (dark: `#0C0D12`).
- Sidebar: `#ECEAF3` (dark: `#0F1117`).
- Panel / raised: white / `#FAF9FC` (dark: `#12141A` / `#161821`).
- Ink / soft / muted: `#14131A` / `#3A3748` / `#6B667A` (inverted in dark).
- Lifecycle fills and foregrounds are semantic tokens on `AppTheme` (draft,
  local, queued, submitted, reviewed, failed, offline). Color never
  communicates a state without a text label.

## Typography

Use SF system text styles only. Respect Dynamic Type through AX5. Do not use
fixed display sizes, minimum scale factors, or text shrinking for interface copy.

## Spacing and shape

- Spacing scale: 4, 8, 12, 16, 24, and 32 points.
- Control radius: 8 points. Grouped section / stage: 12–14 points.
- Frequent controls provide at least a 44 by 44 point target.
- Do not add resting shadows, decorative blur, glow, or glass material.

## Components

Prefer native `NavigationSplitView`, `List`, `Form`, `Section`,
`LabeledContent`, `ContentUnavailableView`, toolbars, sheets, and buttons.

Shared Atelier pieces:

- `StatusPill` and `LifecycleStatus`: labeled lifecycle and sync state.
- `OfflineHonestyBanner`: offline status before media or content.
- `SyncStatusStrip`: connectivity and queue counts.
- `StatusRail`: detail footer for status and privacy scope.
- `MediaStageCard`: evidence-stage container.
- `ResonanceMark`: waveform brand mark.

Keep camera overlays, recording review, feedback composition, PDF layout, and
calendar events local to their workflows.

## Layout

iPad teacher review uses a course sidebar, review queue, and evidence and
feedback workspace.
Compact widths collapse to sequential navigation and sheets. Student capture is
spacious and thumb-friendly; teacher review is denser and keyboard-efficient.

## Motion

Motion conveys state only, normally in 150 to 200 milliseconds. Disable
nonessential movement when Reduce Motion is enabled and avoid endless or
bouncing animation.
