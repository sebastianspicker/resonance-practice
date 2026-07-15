import SwiftData
import SwiftUI

struct NewEntryView: View {
    let courseId: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var authManager: AuthManager
    @EnvironmentObject private var syncManager: SyncManager

    @State private var goalText = ""
    @State private var practiceDate = Date()
    @State private var durationMinutes = ""
    @State private var tags = ""
    @State private var notes = ""
    @State private var entryKind: EntryKind = .practice
    @State private var consentConfirmed = false
    @State private var captureProfile: CaptureProfile = .teacherLearner
    @State private var validationMessage: String?
    @State private var confirmDiscard = false
    @FocusState private var focusedField: Field?

    private enum Field { case goal, duration, tags, notes }
    private let wrapsInNavigationStack: Bool

    init(
        courseId: String,
        initialContent: ScreenshotFormContent? = nil,
        wrapsInNavigationStack: Bool = true
    ) {
        self.courseId = courseId
        self.wrapsInNavigationStack = wrapsInNavigationStack
        _goalText = State(initialValue: initialContent?.goalText ?? "")
        _durationMinutes = State(initialValue: initialContent?.durationMinutes ?? "")
        _tags = State(initialValue: initialContent?.tags ?? "")
        _notes = State(initialValue: initialContent?.notes ?? "")
    }

    var body: some View {
        Group {
            if wrapsInNavigationStack {
                NavigationStack { formContent }
            } else {
                formContent
            }
        }
    }

    private var formContent: some View {
        Form {
                Section("Entry") {
                    Picker("Type", selection: $entryKind) {
                        Text("Practice").tag(EntryKind.practice)
                        Text("Teaching lesson").tag(EntryKind.teachingLesson)
                    }
                    DatePicker("Date", selection: $practiceDate, displayedComponents: [.date, .hourAndMinute])
                }

                Section("Goal") {
                    TextField("What do you want to work on?", text: $goalText, axis: .vertical)
                        .focused($focusedField, equals: .goal)
                    if let validationMessage {
                        Label(validationMessage, systemImage: "exclamationmark.circle")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .accessibilityLabel("Validation error: \(validationMessage)")
                    }
                }

                Section("Practice details") {
                    LabeledContent("Duration") {
                        TextField("Minutes", text: $durationMinutes)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .focused($focusedField, equals: .duration)
                    }
                    TextField("Tags, separated by commas", text: $tags)
                        .focused($focusedField, equals: .tags)
                    Text("Example: intonation, phrasing")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    TextField("Reflection or notes", text: $notes, axis: .vertical)
                        .lineLimit(3...8)
                        .focused($focusedField, equals: .notes)
                }

                if entryKind == .teachingLesson {
                    Section("Private course review") {
                        Toggle("Consent is confirmed", isOn: $consentConfirmed)
                        Text("You can save a draft without consent. Recording, importing, and submitting video remain unavailable until consent for private course review is confirmed.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Picker("Capture profile", selection: $captureProfile) {
                            ForEach(CaptureProfile.allCases) { profile in
                                Text(profile.label).tag(profile)
                            }
                        }
                    }
                }
            }
            .navigationTitle("New entry")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if hasUnsavedChanges { confirmDiscard = true } else { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save draft") { saveEntry() }
                }
            }
        .confirmationDialog("Discard this draft?", isPresented: $confirmDiscard) {
            Button("Discard draft", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) {}
        }
    }

    private var hasUnsavedChanges: Bool {
        !goalText.isEmpty || !durationMinutes.isEmpty || !tags.isEmpty || !notes.isEmpty
    }

    private func saveEntry() {
        validationMessage = nil
        guard let goal = validatedGoal(),
              validateDuration(),
              validateTags(),
              validateNotes(),
              let session = authManager.session
        else { return }

        persist(makeEntry(goal: goal, studentId: session.userId))
    }

    private func validatedGoal() -> String? {
        let goal = goalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty else {
            _ = failValidation("Add a practice goal before saving.", field: .goal)
            return nil
        }
        return goal
    }

    private func validateDuration() -> Bool {
        guard durationMinutes.isEmpty ||
            (Int(durationMinutes).map { (0...480).contains($0) } ?? false)
        else { return failValidation("Duration must be between 0 and 480 minutes.", field: .duration) }
        return true
    }

    private var parsedTags: [String] {
        tags.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }

    private func validateTags() -> Bool {
        guard parsedTags.count <= 30, parsedTags.allSatisfy({ $0.count <= 100 }) else {
            return failValidation("Use no more than 30 tags, with 100 characters per tag.", field: .tags)
        }
        return true
    }

    private func validateNotes() -> Bool {
        guard notes.count <= 10_000 else {
            return failValidation("Notes must contain no more than 10,000 characters.", field: .notes)
        }
        return true
    }

    private func failValidation(_ message: String, field: Field) -> Bool {
        validationMessage = message
        focusedField = field
        return false
    }

    private func makeEntry(goal: String, studentId: String) -> LocalPracticeEntry {
        LocalPracticeEntry(
            id: UUID().uuidString,
            courseId: courseId,
            studentId: studentId,
            details: PracticeEntryDetails(
                practiceDate: practiceDate,
                goalText: goal,
                durationSeconds: Int(durationMinutes).map { $0 * 60 },
                tags: parsedTags,
                notes: notes.isEmpty ? nil : notes
            ),
            status: .draft,
            captureContext: CaptureContext(
                kind: entryKind,
                consentConfirmedAt: entryKind == .teachingLesson && consentConfirmed ? Date() : nil,
                consentScope: entryKind == .teachingLesson && consentConfirmed ? .privateCourseReview : nil,
                captureProfile: entryKind == .teachingLesson ? captureProfile : nil
            )
        )
    }

    private func persist(_ entry: LocalPracticeEntry) {
        modelContext.insert(entry)
        do {
            try modelContext.save()
            syncManager.enqueue(type: .createEntry, payload: ["entryId": entry.id])
            dismiss()
        } catch {
            appState.reportError(error)
        }
    }
}
