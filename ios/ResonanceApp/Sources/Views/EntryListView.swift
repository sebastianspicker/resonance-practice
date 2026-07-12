import SwiftData
import SwiftUI

struct EntryListView: View {
    let courseId: String
    @Query private var entries: [LocalPracticeEntry]
    @State private var showNewEntry = false

    init(courseId: String) {
        self.courseId = courseId
        _entries = Query(
            filter: #Predicate { $0.courseId == courseId && $0.deletedAt == nil },
            sort: \LocalPracticeEntry.practiceDate,
            order: .reverse
        )
    }

    var body: some View {
        List(entries) { entry in
            NavigationLink(value: entry.id) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(entry.goalText).font(.headline).lineLimit(3)
                        Spacer()
                        StatusBadge(status: entry.status)
                    }
                    HStack {
                        Text(entry.practiceDate, style: .date)
                        if let duration = entry.durationSeconds, duration > 0 {
                            Text("· \(formatDuration(duration))")
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            .accessibilityLabel("\(entry.goalText), \(entry.status.displayLabel)")
        }
        .navigationDestination(for: String.self) { entryId in
            if let entry = entries.first(where: { $0.id == entryId }) {
                EntryDetailView(entry: entry)
            }
        }
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView {
                    Label("No entries yet", systemImage: "music.note.list")
                } description: {
                    Text("Create a draft to start recording practice evidence.")
                } actions: {
                    Button("Create entry") { showNewEntry = true }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .toolbar {
            Button("Create entry", systemImage: "plus") { showNewEntry = true }
        }
        .sheet(isPresented: $showNewEntry) { NewEntryView(courseId: courseId) }
    }

    private func formatDuration(_ totalSeconds: Int) -> String {
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        return totalSeconds < 60 ? "\(totalSeconds)s" : "\(minutes) min"
    }
}

private struct StatusBadge: View {
    let status: EntryStatus

    var body: some View {
        Text(status.displayLabel)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.secondary.opacity(0.12), in: Capsule())
            .accessibilityLabel("Status: \(status.displayLabel)")
    }
}

private extension EntryStatus {
    var displayLabel: String {
        switch self {
        case .draft: return "Draft"
        case .submitted: return "Submitted"
        case .reviewed: return "Reviewed"
        }
    }
}
