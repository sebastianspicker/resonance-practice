import SwiftUI

struct NewEntryFormPresentation: View {
    let wrapsInNavigationStack: Bool
    let courseTitle: String?
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
    let hasUnsavedChanges: Bool
    let isSaving: Bool
    @Binding var showsCreatedEntry: Bool
    let createdEntry: LocalPracticeEntry?
    let onCancel: () -> Void
    let onSave: () -> Void
    let onRecord: () -> Void
    let onDiscard: () -> Void
    let onEntryFinish: () -> Void

    var body: some View {
        Group {
            if wrapsInNavigationStack {
                NavigationStack { form }
            } else {
                form
            }
        }
        .interactiveDismissDisabled(hasUnsavedChanges)
    }

    private var form: some View {
        PracticeFlowPage {
            VStack(alignment: .leading, spacing: 20) {
                PracticeFlowHeader(
                    courseTitle: courseTitle ?? "Course unavailable",
                    step: .goal
                )

                PracticeFlowTitle(entryKind == .practice ? "What are you practising?" : "Prepare your lesson.")

                VStack(alignment: .leading, spacing: 18) {
                    NewEntryIdentitySection(
                        courseTitle: courseTitle,
                        entryKind: $entryKind,
                        practiceDate: $practiceDate
                    )
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
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if focusedField.wrappedValue == nil { draftActions }
        }
        .tint(PracticeFlowTheme.accent)
        .navigationBarBackButtonHidden()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                PracticeNavigationTitle(courseTitle: courseTitle ?? "Course unavailable")
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focusedField.wrappedValue = nil }
            }
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: onCancel)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save draft", action: onSave).disabled(isSaving)
            }
        }
        .confirmationDialog("Discard this draft?", isPresented: $confirmDiscard) {
            Button("Discard draft", role: .destructive, action: onDiscard)
            Button("Keep editing", role: .cancel) {}
        }
        .navigationDestination(isPresented: $showsCreatedEntry) {
            if let createdEntry {
                EntryDetailView(
                    entry: createdEntry,
                    initialSection: "guided-record",
                    onFinish: onEntryFinish
                )
            }
        }
    }
    private var draftActions: some View {
        VStack(spacing: 12) {
            Label("Only you until submitted", systemImage: "lock")
                .font(.footnote)
                .foregroundStyle(PracticeFlowTheme.secondary)

            VStack(spacing: 10) {
                Button(action: onRecord) {
                    Label(
                        entryKind == .practice ? "Record audio" : "Continue to capture",
                        systemImage: entryKind == .practice ? "mic" : "video"
                    )
                }
                .buttonStyle(PracticeFlowButtonStyle())
                .disabled(isSaving)
                .accessibilityHint(
                    entryKind == .practice
                        ? "Saves this private draft and opens audio recording."
                        : "Saves this private draft and opens lesson capture."
                )

                Button("Save draft", action: onSave)
                    .buttonStyle(PracticeFlowButtonStyle(primary: false))
                    .disabled(isSaving)
            }
        }
        .frame(maxWidth: 600)
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        .background(PracticeFlowTheme.background)
    }

}

private struct NewEntryIdentitySection: View {
    let courseTitle: String?
    @Binding var entryKind: EntryKind
    @Binding var practiceDate: Date

    var body: some View {
        VStack(spacing: 8) {
            LabeledContent("Course") {
                Text(courseTitle ?? "Course unavailable")
                    .foregroundStyle(PracticeFlowTheme.ink)
                    .multilineTextAlignment(.trailing)
            }
            .practiceField()

            LabeledContent("Entry type") {
                Picker("Entry type", selection: $entryKind) {
                    Text("Practice").tag(EntryKind.practice)
                    Text("Teaching lesson").tag(EntryKind.teachingLesson)
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            .practiceField()

            LabeledContent("Date") {
                DatePicker("Practice date and time", selection: $practiceDate, displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    .datePickerStyle(.compact)
            }
            .practiceField()
        }
    }
}

private struct NewEntryGoalSection: View {
    @Binding var goalText: String
    let validationMessage: String?
    var focusedField: FocusState<NewEntryDraftField?>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            NewEntryFieldLabel("Practice goal")
            TextField("What do you want to work on?", text: $goalText, axis: .vertical)
                .focused(focusedField, equals: .goal)
                .lineLimit(2...6)
                .practiceField()
            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(PracticeFlowTheme.warning)
                    .accessibilityLabel("Validation error: \(validationMessage)")
            }
        }
    }
}

private struct NewEntryPracticeDetailsSection: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding var durationMinutes: String
    @Binding var tags: String
    @Binding var notes: String
    var focusedField: FocusState<NewEntryDraftField?>.Binding
    @State private var showsAdditionalDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !dynamicTypeSize.isAccessibilitySize {
                HStack(alignment: .top, spacing: 10) {
                    durationField
                    tagsField
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    durationField
                    tagsField
                }
            }

            DisclosureGroup("Additional details", isExpanded: $showsAdditionalDetails) {
                VStack(alignment: .leading, spacing: 8) {
                    NewEntryFieldLabel("Reflection or notes (optional)")
                    TextField("Reflection or notes", text: $notes, axis: .vertical)
                        .lineLimit(3...8)
                        .focused(focusedField, equals: .notes)
                        .practiceField()
                }
                .padding(.top, 8)
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(PracticeFlowTheme.secondary)
            .onChange(of: focusedField.wrappedValue) { _, field in
                if field == .notes { showsAdditionalDetails = true }
            }
        }
    }

    private var durationField: some View {
        VStack(alignment: .leading, spacing: 6) {
            NewEntryFieldLabel("Duration (optional)")
            TextField("Minutes", text: $durationMinutes)
                .keyboardType(.numberPad)
                .focused(focusedField, equals: .duration)
                .practiceField()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tagsField: some View {
        VStack(alignment: .leading, spacing: 6) {
            NewEntryFieldLabel("Tags (optional)")
            TextField("Comma-separated", text: $tags)
                .focused(focusedField, equals: .tags)
                .practiceField()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Confirms private course review and capture profile for a new teaching-lesson draft.
private struct NewEntryTeachingLessonConsentSection: View {
    @Binding var consentConfirmed: Bool
    @Binding var captureProfile: CaptureProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NewEntryFieldLabel("Private course review")
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
                .practiceField()
                .background(consentConfirmed ? PracticeFlowTheme.audioSurface : Color.clear)
                .foregroundStyle(consentConfirmed ? PracticeFlowTheme.accent : PracticeFlowTheme.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Private course review")
            .accessibilityValue(consentConfirmed ? "Confirmed" : "Not confirmed")
            .accessibilityHint("Confirms that lesson video stays private to teachers in this course")

            Text("Video stays private to teachers in this course. It is not shared publicly.")
                .font(.footnote)
                .foregroundStyle(PracticeFlowTheme.secondary)

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
                .foregroundStyle(PracticeFlowTheme.secondary)
        }
    }
}

private struct NewEntryFieldLabel: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(PracticeFlowTheme.secondary)
    }
}
