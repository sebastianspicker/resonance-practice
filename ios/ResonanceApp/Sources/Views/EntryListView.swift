import SwiftUI
import SwiftData

struct EntryListView: View {
    let courseId: String
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var syncManager: SyncManager
    @Environment(\.modelContext) private var modelContext
    @Query private var entries: [LocalPracticeEntry]
    @State private var showNewEntry = false

    init(courseId: String) {
        self.courseId = courseId
        _entries = Query(filter: #Predicate { $0.courseId == courseId && $0.deletedAt == nil }, sort: \LocalPracticeEntry.practiceDate, order: .reverse)
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                ForEach(entries) { entry in
                    NavigationLink(destination: EntryDetailView(entry: entry)) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .top) {
                                Text(entry.goalText)
                                    .font(.headline.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .multilineTextAlignment(.leading)
                                    .lineLimit(3)
                                    .minimumScaleFactor(0.85)
                                Spacer(minLength: 16)
                                StatusBadge(status: entry.status)
                            }
                            HStack {
                                Text(entry.practiceDate, style: .date)
                                    .font(.subheadline)
                                    .foregroundStyle(.white.opacity(0.7))
                                if let duration = entry.durationSeconds, duration > 0 {
                                    Text("\u{2022} \(formatDuration(duration))")
                                        .font(.subheadline)
                                        .foregroundStyle(.white.opacity(0.7))
                                }
                            }
                        }
                        .glassCard()
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(entry.goalText), \(entry.status.rawValue)")
                }
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 20)
        }
        .scrollContentBackground(.hidden)
        .safeAreaPadding(.horizontal, 8)
        .overlay {
            if entries.isEmpty {
                EmptyStateView(
                    icon: "music.note.list",
                    title: "No entries yet",
                    description: "Create your first practice entry for this course.",
                    actionLabel: "New Entry"
                ) {
                    showNewEntry = true
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Entry") { showNewEntry = true }
            }
        }
        .sheet(isPresented: $showNewEntry) {
            NewEntryView(courseId: courseId)
        }
    }

    private func formatDuration(_ totalSeconds: Int) -> String {
        if totalSeconds < 60 {
            return "\(totalSeconds)s"
        }
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        return "\(minutes) min"
    }
}

private struct StatusBadge: View {
    let status: EntryStatus

    var body: some View {
        Text(label)
            .font(.caption.weight(.bold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(color.opacity(0.2))
            .foregroundStyle(color)
            .clipShape(Capsule())
            .overlay(
                Capsule().stroke(color.opacity(0.5), lineWidth: 1)
            )
            .accessibilityLabel("Status: \(label)")
    }

    private var label: String {
        switch status {
        case .draft: return "DRAFT"
        case .submitted: return "SUBMITTED"
        case .reviewed: return "REVIEWED"
        }
    }

    private var color: Color {
        switch status {
        case .draft: return .white.opacity(0.6)
        case .submitted: return .orange
        case .reviewed: return .green
        }
    }
}
