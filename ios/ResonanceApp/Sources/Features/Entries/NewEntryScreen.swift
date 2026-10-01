import SwiftData
import SwiftUI

struct NewEntryScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var authManager: AuthManager
    @EnvironmentObject private var syncManager: SyncManager

    let courseId: String
    private let wrapsInNavigationStack: Bool
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
    @State private var pendingEntry: LocalPracticeEntry?
    @State private var createdEntry: LocalPracticeEntry?
    @State private var showsCreatedEntry = false
    @State private var isSaving = false
    @State private var originalPracticeDate: Date?
    @Query(sort: \LocalCourse.title) private var courses: [LocalCourse]
    @FocusState private var focusedField: NewEntryDraftField?

    init(
        courseId: String,
        initialContent: ScreenshotFormContent?,
        wrapsInNavigationStack: Bool
    ) {
        self.courseId = courseId
        self.wrapsInNavigationStack = wrapsInNavigationStack
        _goalText = State(initialValue: initialContent?.goalText ?? "")
        _durationMinutes = State(initialValue: initialContent?.durationMinutes ?? "")
        _tags = State(initialValue: initialContent?.tags ?? "")
        _notes = State(initialValue: initialContent?.notes ?? "")
    }

    private var draft: NewEntryDraft {
        NewEntryDraft(
            courseId: courseId, goalText: goalText, practiceDate: practiceDate,
            durationMinutes: durationMinutes, tags: tags, notes: notes, entryKind: entryKind,
            consentConfirmed: consentConfirmed, captureProfile: captureProfile
        )
    }

    private var hasUnsavedChanges: Bool {
        !goalText.isEmpty || !durationMinutes.isEmpty || !tags.isEmpty || !notes.isEmpty
            || entryKind != .practice || consentConfirmed || captureProfile != .teacherLearner
            || originalPracticeDate.map { $0 != practiceDate } == true
    }

    private var courseTitle: String? {
        courses.first(where: { $0.id == courseId })?.title
    }

    var body: some View {
        NewEntryFormPresentation(
            wrapsInNavigationStack: wrapsInNavigationStack,
            courseTitle: courseTitle,
            goalText: $goalText, practiceDate: $practiceDate, durationMinutes: $durationMinutes,
            tags: $tags, notes: $notes, entryKind: $entryKind,
            consentConfirmed: $consentConfirmed, captureProfile: $captureProfile,
            validationMessage: validationMessage, focusedField: $focusedField,
            confirmDiscard: $confirmDiscard, hasUnsavedChanges: hasUnsavedChanges, isSaving: isSaving,
            showsCreatedEntry: $showsCreatedEntry, createdEntry: createdEntry,
            onCancel: cancelEntry, onSave: { saveEntry(for: .draft) },
            onRecord: { saveEntry(for: .guidedCapture) }, onDiscard: discardEntry,
            onEntryFinish: { dismiss() }
        )
        .onChange(of: showsCreatedEntry) { _, isPresented in
            guard !isPresented, createdEntry != nil else { return }
            isSaving = false
            dismiss()
        }
        .onAppear {
            if originalPracticeDate == nil {
                originalPracticeDate = practiceDate
            }
        }
    }

    private func cancelEntry() {
        if hasUnsavedChanges { confirmDiscard = true } else { dismiss() }
    }

    private func discardEntry() {
        if let pendingEntry {
            modelContext.delete(pendingEntry)
            self.pendingEntry = nil
        }
        dismiss()
    }

    private func saveEntry(for destination: NewEntrySaveDestination) {
        guard !isSaving else { return }
        validationMessage = nil
        do {
            try draft.validate()
        } catch let error as NewEntryDraftValidationError {
            validationMessage = error.message
            focusedField = error.field
            return
        } catch {
            appState.reportError(error)
            return
        }
        guard let session = authManager.session else {
            appState.reportError(NewEntryScreenError.sessionMissing)
            return
        }

        let entry: LocalPracticeEntry
        if let pendingEntry, pendingEntry.studentId == session.userId {
            entry = pendingEntry
            applyCurrentDraft(to: entry)
        } else {
            entry = draft.makeEntry(studentId: session.userId)
            pendingEntry = entry
            modelContext.insert(entry)
        }
        persist(entry, destination: destination)
    }

    private func persist(_ entry: LocalPracticeEntry, destination: NewEntrySaveDestination) {
        isSaving = true
        do {
            try modelContext.save()
            syncManager.enqueue(type: .createEntry, payload: .entry(.init(entryId: entry.id)))
            pendingEntry = nil
            switch destination {
            case .draft:
                dismiss()
            case .guidedCapture:
                createdEntry = entry
                showsCreatedEntry = true
            }
        } catch {
            isSaving = false
            appState.reportError(error)
        }
    }

    private func applyCurrentDraft(to entry: LocalPracticeEntry) {
        entry.practiceDate = draft.practiceDate
        entry.goalText = draft.goalText.trimmingCharacters(in: .whitespacesAndNewlines)
        entry.durationSeconds = Int(draft.durationMinutes).map { $0 * 60 }
        entry.tags = draft.parsedTags
        entry.notes = draft.notes.isEmpty ? nil : draft.notes
        entry.kind = draft.entryKind
        entry.consentConfirmedAt = draft.entryKind == .teachingLesson && draft.consentConfirmed ? Date() : nil
        entry.consentScope = draft.entryKind == .teachingLesson && draft.consentConfirmed ? .privateCourseReview : nil
        entry.captureProfile = draft.entryKind == .teachingLesson ? draft.captureProfile : nil
        entry.updatedAt = Date()
    }
}

private enum NewEntrySaveDestination {
    case draft
    case guidedCapture
}

private enum NewEntryScreenError: LocalizedError {
    case sessionMissing

    var errorDescription: String? {
        "Your session is no longer available. Sign in again before saving this draft."
    }
}
