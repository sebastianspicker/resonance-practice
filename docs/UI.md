# Native UI Implementation Guide

Resonance is a calm, offline-first workflow application. [PRODUCT.md](../PRODUCT.md) defines
the product register and [DESIGN.md](../DESIGN.md) defines the semantic visual system.

## Routes

```text
University sign-in
└── Courses
    ├── Student course: Entries → Draft/capture → Entry detail/feedback
    └── Teacher course: To review / Reviewed → Submission detail → Feedback

Sidebar tools: Calendar, Export (student course only), Sync status, Settings
```

Course membership role is the authority for visible actions. Teachers are not
offered entry creation or export. Students do not receive teacher-review tools.

## Shared Interaction Patterns

- Use native `NavigationSplitView`, `List`, `Form`, `Section`, toolbars, sheets,
  and `ContentUnavailableView`.
- Keep existing content visible during refresh. Put recoverable errors beside
  the affected content with a specific retry action.
- Describe local, queued, uploading, submitted, reviewed, stale, and failed
  states in text. Color is supplementary.
- A submission tap queues its upload and metadata dependencies plus submission.
  Repeated taps coalesce by task and entity.
- Manual sign-out discloses pending and failed work and deletes local profile
  data only after a destructive confirmation.
- Teacher playback uses an authorized short-lived URL. It is never cached as a
  teacher media file; expired and offline states remain retryable.

## Forms and Capture

Forms use persistent labels, inline validation, first-error focus, explicit
save/cancel, and unsaved-change confirmation. Duration is entered in localized
minutes. Teaching-lesson drafts can be saved without consent, but recording,
import, and submission require explicit private-course-review consent.

Audio and video capture must provide preview, accept, and retake paths. Camera
guidance is only a composition aid; it does not analyze people or teaching.

## Pilot Accessibility and Adaptation Requirements

- Deployment floor: iOS/iPadOS 17.
- Validate all Dynamic Type sizes through AX5 without shrinking text.
- Validate core student course, draft, capture, sync, and feedback flows on iPhone.
- Validate iPad portrait, landscape, split view, and resizable windows.
- Frequent targets are at least 44 by 44 points.
- Respect Bold Text, Increase Contrast, Reduce Motion, and Reduce Transparency.
- Provide useful VoiceOver labels, values, focus order, and keyboard traversal.
- German-primary and complete-English localization remains open; the current source contains English literals and no String Catalog.

## Validation

Every primary screen is exercised in loading, empty, offline, permission-denied,
recoverable-error, and terminal-error states. Release validation covers light
and dark appearance, German and English, iPhone and iPad, Large/AX1/AX3/AX5
text, keyboard, VoiceOver, Voice Control, and Switch Control.

These are acceptance requirements. They have not all been exercised in the current local checkout; see the release checklist for the open matrix.
