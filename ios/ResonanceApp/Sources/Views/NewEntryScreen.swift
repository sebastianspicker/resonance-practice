import SwiftData
import SwiftUI

// Owns new-entry draft state, validation focus, persistence, and queue ordering.

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
    }

    var body: some View {
        NewEntryFormPresentation(
            wrapsInNavigationStack: wrapsInNavigationStack,
            goalText: $goalText, practiceDate: $practiceDate, durationMinutes: $durationMinutes,
            tags: $tags, notes: $notes, entryKind: $entryKind,
            consentConfirmed: $consentConfirmed, captureProfile: $captureProfile,
            validationMessage: validationMessage, focusedField: $focusedField,
            confirmDiscard: $confirmDiscard, onCancel: cancelEntry, onSave: saveEntry,
            onDiscard: { dismiss() }
        )
    }

    private func cancelEntry() {
        if hasUnsavedChanges { confirmDiscard = true } else { dismiss() }
    }

    private func saveEntry() {
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
        guard let session = authManager.session else { return }
        persist(draft.makeEntry(studentId: session.userId))
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
