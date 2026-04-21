import SwiftUI
import SwiftData

struct NewEntryView: View {
    let courseId: String
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var syncManager: SyncManager
    @Environment(\.modelContext) private var modelContext

    @State private var goalText = ""
    @State private var practiceDate = Date()
    @State private var durationSeconds = ""
    @State private var tags = ""
    @State private var notes = ""
    @State private var selectedTemplateId: String = EntryTemplate.defaults.first?.id ?? ""
    @State private var showValidationAlert = false
    @State private var validationMessage = ""

    // Limits matching server config.ts
    private static let maxDurationSeconds = 28_800  // 8 hours
    private static let maxTags = 30
    private static let maxTagLength = 100
    private static let maxNotesLength = 10_000

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.PremiumBackground()
                
                ScrollView {
                    VStack(spacing: 24) {
                        // Template Section
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Template")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.6))
                                .textCase(.uppercase)
                            
                            Picker("Preset", selection: $selectedTemplateId) {
                                ForEach(EntryTemplate.defaults) { template in
                                    Text(template.name).tag(template.id)
                                }
                            }
                            .tint(.white)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityLabel("Practice template")
                            .accessibilityHint("Select a template to pre-fill the entry form")

                            Button("Apply Template") {
                                applySelectedTemplate()
                            }
                            .buttonStyle(SubtleGlassButtonStyle())
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel("Apply template")
                            .accessibilityHint("Double-tap to fill in goal, tags, and notes from the selected template")
                        }
                        .glassCard()
                        
                        // Goal Section
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Goal")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.6))
                                .textCase(.uppercase)
                            
                            GlassTextField(placeholder: "Goal text", text: $goalText)
                                .accessibilityLabel("Goal text")
                                .accessibilityHint("Enter your practice goal")
                        }
                        .glassCard()

                        // Practice Section
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Practice")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.6))
                                .textCase(.uppercase)
                            
                            DatePicker("Date", selection: $practiceDate, displayedComponents: [.date, .hourAndMinute])
                                .colorScheme(.dark)
                            
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("Duration")
                                        .foregroundStyle(.white)
                                    Spacer()
                                    GlassTextField(placeholder: "0", text: $durationSeconds, keyboardType: .numberPad, cornerRadius: 8, width: 100)
                                        .multilineTextAlignment(.trailing)
                                        .accessibilityLabel("Duration in seconds")
                                        .accessibilityHint("Enter practice duration in seconds")
                                    Text("sec")
                                        .font(.caption)
                                        .foregroundStyle(.white.opacity(0.5))
                                }
                                if let dur = Int(durationSeconds), dur > 0 {
                                    Text(durationHint(dur))
                                        .font(.caption)
                                        .foregroundStyle(.white.opacity(0.5))
                                        .transition(.opacity)
                                }
                            }
                        }
                        .glassCard()

                        // Tags Section
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Tags")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.6))
                                .textCase(.uppercase)
                            
                            GlassTextField(placeholder: "Comma-separated tags", text: $tags)
                                .accessibilityLabel("Tags")
                                .accessibilityHint("Enter comma-separated tags for this entry")
                        }
                        .glassCard()

                        // Notes Section
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Notes")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.6))
                                .textCase(.uppercase)
                            
                            GlassTextField(placeholder: "Notes", text: $notes, axis: .vertical, lineLimit: 4...8)
                                .accessibilityLabel("Notes")
                                .accessibilityHint("Enter additional notes about your practice session")
                        }
                        .glassCard()
                    }
                    .padding()
                }
            }
            .navigationTitle("New Entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save Draft") { saveEntry() }
                        .disabled(goalText.isEmpty)
                        .foregroundStyle(goalText.isEmpty ? .white.opacity(0.5) : .white)
                        .accessibilityLabel("Save entry as draft")
                        .accessibilityHint(goalText.isEmpty ? "Enter a goal first" : "Double-tap to save this practice entry as a draft. You can record audio and submit later.")
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.white)
                        .accessibilityLabel("Cancel")
                        .accessibilityHint("Double-tap to discard this entry and go back")
                }
            }
            .alert("Validation Error", isPresented: $showValidationAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(validationMessage)
            }
        }
    }

    /// Validates all form fields against server limits.
    /// Returns an error message if validation fails, nil if valid.
    private func validateForm() -> String? {
        // Goal text: must be non-empty
        let trimmedGoal = goalText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedGoal.isEmpty {
            return "Goal text is required."
        }

        // Duration: must be 0..28800
        if !durationSeconds.isEmpty {
            guard let dur = Int(durationSeconds) else {
                return "Duration must be a whole number of seconds."
            }
            if dur < 0 || dur > Self.maxDurationSeconds {
                return "Duration must be between 0 and \(Self.maxDurationSeconds) seconds (8 hours)."
            }
        }

        // Tags: max 30, each max 100 characters
        let parsedTags = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if parsedTags.count > Self.maxTags {
            return "Too many tags (\(parsedTags.count)). Maximum is \(Self.maxTags)."
        }
        if let longTag = parsedTags.first(where: { $0.count > Self.maxTagLength }) {
            return "Tag \"\(String(longTag.prefix(20)))...\" exceeds \(Self.maxTagLength) characters."
        }

        // Notes: max 10000 characters
        if notes.count > Self.maxNotesLength {
            return "Notes exceed \(Self.maxNotesLength) characters (\(notes.count) entered)."
        }

        return nil
    }

    private func saveEntry() {
        if let error = validateForm() {
            validationMessage = error
            showValidationAlert = true
            return
        }

        guard let session = authManager.session else { return }
        let entry = LocalPracticeEntry(
            id: UUID().uuidString,
            courseId: courseId,
            studentId: session.userId,
            practiceDate: practiceDate,
            goalText: goalText,
            durationSeconds: Int(durationSeconds),
            tags: tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) },
            notes: notes.isEmpty ? nil : notes,
            status: .draft
        )
        modelContext.insert(entry)
        do {
            try modelContext.save()
        } catch {
            appState.reportError(error)
            return
        }
        syncManager.enqueue(type: .createEntry, payload: ["entryId": entry.id])
        dismiss()
    }

    private func durationHint(_ totalSeconds: Int) -> String {
        if totalSeconds < 60 {
            return "\(totalSeconds) seconds"
        }
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        if hours > 0 {
            return minutes > 0 ? "= \(hours)h \(minutes)m" : "= \(hours)h"
        }
        return secs > 0 ? "= \(minutes)m \(secs)s" : "= \(minutes) min"
    }

    private func applySelectedTemplate() {
        guard let template = EntryTemplate.defaults.first(where: { $0.id == selectedTemplateId }) else {
            return
        }
        goalText = template.goalText
        tags = template.tags.joined(separator: ", ")
        notes = template.notes
    }
}

private struct EntryTemplate: Identifiable {
    let id: String
    let name: String
    let goalText: String
    let tags: [String]
    let notes: String

    static let defaults: [EntryTemplate] = [
        EntryTemplate(
            id: "warmup-technique",
            name: "Warmup + Technik",
            goalText: "Intonation and clean articulation in warmup patterns",
            tags: ["warmup", "technique"],
            notes: "Focus on relaxed breathing and even tone."
        ),
        EntryTemplate(
            id: "repertoire-polish",
            name: "Repertoire Polish",
            goalText: "Polish difficult measures in current repertoire",
            tags: ["repertoire", "precision"],
            notes: "Slow tempo first, then raise BPM gradually."
        ),
        EntryTemplate(
            id: "performance-run",
            name: "Performance Run",
            goalText: "Full run-through with stage-ready dynamics",
            tags: ["performance", "expression"],
            notes: "Record one uninterrupted take."
        )
    ]
}
