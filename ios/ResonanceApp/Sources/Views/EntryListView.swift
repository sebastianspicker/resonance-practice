import SwiftData
import SwiftUI

// Lists course entries with filtering and selection behavior for the course workflow.

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
                        StatusPill(
                            status: entry.status.studentLifecycle(
                                isRemoteBacked: entry.remoteUpdatedAt != nil
                            )
                        )
                    }
                    HStack(spacing: 0) {
                        Text(entry.practiceDate, style: .date)
                        if let duration = entry.durationSeconds, duration > 0 {
                            Text(" · \(formatDuration(duration))")
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.workspaceMuted)
                }
                .padding(.vertical, 4)
            }
            .accessibilityLabel(
                "\(entry.goalText), \(entry.status.studentLifecycle(isRemoteBacked: entry.remoteUpdatedAt != nil).label)"
            )
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(AppTheme.workspaceBackground)
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
