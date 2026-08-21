import SwiftUI

// Presents the complete new-entry form with explicit state and action bindings.

struct NewEntryFormPresentation: View {
    let wrapsInNavigationStack: Bool
    @Binding var goalText: String
    @Binding var practiceDate: Date
    @Binding var durationMinutes: String
    @Binding var tags: String
    @Binding var notes: String
    @Binding var entryKind: EntryKind
    @Binding var consentConfirmed: Bool
    @Binding var captureProfile: CaptureProfile
    let validationMessage: String?
    var focusedField: FocusState<NewEntryDraftField?>.Binding
    @Binding var confirmDiscard: Bool
    let onCancel: () -> Void
    let onSave: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        Group {
            if wrapsInNavigationStack {
                NavigationStack { form }
            } else {
                form
            }
        }
    }

    private var form: some View {
        Form {
            NewEntryIdentitySection(entryKind: $entryKind, practiceDate: $practiceDate)
            NewEntryGoalSection(
                goalText: $goalText,
                validationMessage: validationMessage,
                focusedField: focusedField
            )
            NewEntryPracticeDetailsSection(
                durationMinutes: $durationMinutes,
                tags: $tags,
                notes: $notes,
                focusedField: focusedField
            )
            if entryKind == .teachingLesson {
                NewEntryTeachingLessonConsentSection(
                    consentConfirmed: $consentConfirmed,
                    captureProfile: $captureProfile
                )
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppTheme.workspaceBackground)
        .navigationTitle("New entry")
        .navigationBarBackButtonHidden(!wrapsInNavigationStack)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: onCancel)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save draft", action: onSave)
            }
        }
        .confirmationDialog("Discard this draft?", isPresented: $confirmDiscard) {
            Button("Discard draft", role: .destructive, action: onDiscard)
            Button("Keep editing", role: .cancel) {}
        }
    }
}

private struct NewEntryIdentitySection: View {
    @Binding var entryKind: EntryKind
    @Binding var practiceDate: Date

    var body: some View {
        Section("Entry") {
            Picker("Type", selection: $entryKind) {
                Text("Practice").tag(EntryKind.practice)
                Text("Teaching lesson").tag(EntryKind.teachingLesson)
            }
            DatePicker("Date", selection: $practiceDate, displayedComponents: [.date, .hourAndMinute])
        }
    }
}

private struct NewEntryGoalSection: View {
    @Binding var goalText: String
    let validationMessage: String?
    var focusedField: FocusState<NewEntryDraftField?>.Binding

    var body: some View {
        Section("Goal") {
            TextField("What do you want to work on?", text: $goalText, axis: .vertical)
                .focused(focusedField, equals: .goal)
            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Validation error: \(validationMessage)")
            }
        }
    }
}

private struct NewEntryPracticeDetailsSection: View {
    @Binding var durationMinutes: String
    @Binding var tags: String
    @Binding var notes: String
    var focusedField: FocusState<NewEntryDraftField?>.Binding

    var body: some View {
        Section("Practice details") {
            LabeledContent("Duration") {
                TextField("Minutes", text: $durationMinutes)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .focused(focusedField, equals: .duration)
            }
            TextField("Tags, separated by commas", text: $tags)
                .focused(focusedField, equals: .tags)
            Text("Example: intonation, phrasing")
                .font(.footnote)
                .foregroundStyle(.secondary)
            TextField("Reflection or notes", text: $notes, axis: .vertical)
                .lineLimit(3...8)
                .focused(focusedField, equals: .notes)
        }
    }
}

/// Confirms private course review and capture profile for a new teaching-lesson draft.
private struct NewEntryTeachingLessonConsentSection: View {
    @Binding var consentConfirmed: Bool
    @Binding var captureProfile: CaptureProfile

    var body: some View {
        Section("Private course review") {
            Button {
                consentConfirmed.toggle()
            } label: {
                HStack(spacing: 8) {
                    if consentConfirmed {
                        Text("● Private course review")
                            .font(.subheadline.weight(.semibold))
                    } else {
                        Text("Private course review · not confirmed")
                            .font(.subheadline.weight(.medium))
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    if consentConfirmed {
                        Capsule(style: .continuous)
                            .fill(AppTheme.selection)
                            .overlay(
                                Capsule(style: .continuous)
                                    .strokeBorder(AppTheme.accent.opacity(0.55), lineWidth: 1)
                            )
                    } else {
                        Capsule(style: .continuous)
                            .strokeBorder(AppTheme.workspaceBorderStrong, lineWidth: 1)
                    }
                }
                .foregroundStyle(consentConfirmed ? AppTheme.accent : AppTheme.workspaceInkSoft)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Private course review")
            .accessibilityValue(consentConfirmed ? "Confirmed" : "Not confirmed")
            .accessibilityHint("Confirms that lesson video stays private to teachers in this course")

            Text("Video stays private to teachers in this course. It is not shared publicly.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Picker("Capture profile", selection: $captureProfile) {
                ForEach(CaptureProfile.allCases) { profile in
                    Text(profile.label).tag(profile)
                }
            }

            Text(
                "You can save a draft without consent. Film lesson, import video, and submit stay unavailable until "
                    + "private course review is confirmed."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }
}
