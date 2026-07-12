# Design System

## Theme

Follow the system light and dark appearances. Use semantic Apple backgrounds,
labels, fills, separators, and status colors. Never force an appearance.

## Color

- Primary action: Resonance violet `#5E3FC4` with white text.
- Accent foreground: `#5E3FC4` in light appearance and `#B7A8FF` in dark appearance.
- Soft selection: `#F0EDFF` in light appearance and `#26213A` in dark appearance.
- Error, warning, success, text, and surfaces use system semantic colors.
- Color never communicates a state without a text label or accessible value.

## Typography

Use SF system text styles only. Respect Dynamic Type through AX5. Do not use
fixed display sizes, minimum scale factors, or text shrinking for interface copy.

## Spacing and Shape

- Spacing scale: 4, 8, 12, 16, 24, and 32 points.
- Custom controls use an 8-point radius.
- The rare grouped custom surface uses a 12-point radius.
- Frequent controls provide at least a 44 by 44 point target.
- Do not add resting shadows, decorative blur, glow, or glass material.

## Components

Prefer native `NavigationSplitView`, `List`, `Form`, `Section`,
`LabeledContent`, `ContentUnavailableView`, toolbars, sheets, and buttons.
Standardize status labels, sync state, inline notices, field errors,
loading/empty/error presentation, and media playback controls. Keep camera
overlays, recording review, feedback composition, PDF layout, and calendar
events local to their workflows.

## Layout

iPad uses a sidebar and detail presentation. Compact widths collapse to
sequential navigation. Student capture is spacious and thumb-friendly; teacher
review is denser and keyboard-efficient. Replace fixed-width fields and rigid
horizontal groups with adaptive layouts.

## Motion

Motion conveys state only, normally in 150 to 200 milliseconds. Disable
nonessential movement when Reduce Motion is enabled and avoid endless or
bouncing animation.
