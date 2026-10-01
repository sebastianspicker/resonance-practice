import SwiftUI
import SwiftData

// Lets a learner select course activity and export it as a PDF summary.

struct ExportView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var startDate = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
    @State private var endDate = Date()
    @State private var exportURL: URL?
    @State private var errorMessage: String?
    @State private var showErrorAlert = false
    @State private var showEmptyRangeMessage = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Date Range") {
                    DatePicker("Start", selection: $startDate, displayedComponents: [.date])
                        .accessibilityLabel("Start date")
                    DatePicker("End", selection: $endDate, displayedComponents: [.date])
                        .accessibilityLabel("End date")

                    HStack(spacing: 8) {
                        quickFilterButton("Last 7 Days", days: -7)
                        quickFilterButton("Last 30 Days", days: -30)
                        quickFilterButton("This Semester", days: -180)
                    }
                    .buttonStyle(.borderless)
                }

                if let stats = buildStats(entries: entriesInRange()) {
                    Section("Practice Stats") {
                        statRow("Entries", value: "\(stats.entryCount)")
                        statRow("Total Duration", value: formatDuration(stats.totalDurationSeconds))
                        statRow("Draft", value: "\(stats.draftCount)")
                        statRow("Submitted", value: "\(stats.submittedCount)")
                        statRow("Reviewed", value: "\(stats.reviewedCount)")
                    }
                }

                Button("Generate PDF") {
                    generate()
                }
                .accessibilityHint("Creates a PDF report of practice entries in the selected date range")

                if let exportURL {
                    ShareLink("Share PDF", item: exportURL)
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppTheme.workspaceBackground)
            .navigationTitle("Export")
            .alert("Export failed", isPresented: $showErrorAlert) {
                Button("OK") { showErrorAlert = false; errorMessage = nil }
            } message: {
                if let errorMessage { Text(errorMessage) }
            }
            .alert("No entries", isPresented: $showEmptyRangeMessage) {
                Button("OK") { showEmptyRangeMessage = false }
            } message: {
                Text("No entries in the selected date range.")
            }
        }
    }

    private func quickFilterButton(_ label: String, days: Int) -> some View {
        Button(label) {
            startDate = Calendar.current.date(byAdding: .day, value: days, to: Date()) ?? Date()
            endDate = Date()
        }
        .font(.caption)
    }

    private func generate() {
        errorMessage = nil
        let entries = entriesInRange()

        if entries.isEmpty {
            showEmptyRangeMessage = true
            return
        }

        let filename = "Resonance_Export_\(Int(Date().timeIntervalSince1970))_\(UUID().uuidString.prefix(8)).pdf"
        guard let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            errorMessage = "Documents directory unavailable"
            showErrorAlert = true
            return
        }
        let exportDir = documentsDir.appendingPathComponent("Exports", isDirectory: true)
        let url = exportDir.appendingPathComponent(filename)

        do {
            try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)

            try PDFExporter.export(entries: entries, to: url)
            FileStore.setFileProtection(url: url)
            exportURL = url
        } catch {
            errorMessage = error.localizedDescription
            showErrorAlert = true
        }
    }

    private func entriesInRange() -> [LocalPracticeEntry] {
        // Normalize startDate to start-of-day and endDate to end-of-day so the
        // date-only picker range includes all entries on the selected dates.
        // Without this, the retained time component from the initial Date() value
        // could exclude entries later in the day on the end date.
        let calendar = Calendar.current
        let rangeStart = calendar.startOfDay(for: startDate)
        let rangeEnd: Date = {
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: endDate)) else {
                return endDate
            }
            return nextDay
        }()
        var descriptor = FetchDescriptor<LocalPracticeEntry>(
            predicate: #Predicate { $0.practiceDate >= rangeStart && $0.practiceDate < rangeEnd && $0.deletedAt == nil }
        )
        descriptor.sortBy = [SortDescriptor(\.practiceDate, order: .forward)]
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    private func buildStats(entries: [LocalPracticeEntry]) -> ExportStats? {
        guard entries.isEmpty == false else { return nil }
        let totalDuration = entries.reduce(0) { partial, entry in
            partial + (entry.durationSeconds ?? 0)
        }
        let draftCount = entries.filter { $0.status == .draft }.count
        let submittedCount = entries.filter { $0.status == .submitted }.count
        let reviewedCount = entries.filter { $0.status == .reviewed }.count
        return ExportStats(
            entryCount: entries.count,
            totalDurationSeconds: totalDuration,
            draftCount: draftCount,
            submittedCount: submittedCount,
            reviewedCount: reviewedCount
        )
    }

    private func formatDuration(_ totalSeconds: Int) -> String {
        if totalSeconds < 60 {
            return "\(totalSeconds)s"
        }
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        return seconds > 0 ? "\(minutes)m \(seconds)s" : "\(minutes)m"
    }

    private func statRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ExportStats {
    let entryCount: Int
    let totalDurationSeconds: Int
    let draftCount: Int
    let submittedCount: Int
    let reviewedCount: Int
}
