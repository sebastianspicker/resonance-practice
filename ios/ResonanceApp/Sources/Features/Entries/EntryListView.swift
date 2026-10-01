import SwiftData
import SwiftUI

// Lists course entries with filtering and selection behavior for the course workflow.

struct EntryListView: View {
    let courseId: String
    @Query private var entries: [LocalPracticeEntry]
    @EnvironmentObject private var networkMonitor: NetworkMonitor
    @EnvironmentObject private var syncManager: SyncManager
    @State private var showNewEntry = false
    @State private var journalDays: [JournalDay] = []

    init(courseId: String) {
        self.courseId = courseId
        _entries = Query(
            filter: #Predicate { $0.courseId == courseId && $0.deletedAt == nil },
            sort: \LocalPracticeEntry.practiceDate,
            order: .reverse
        )
    }

    var body: some View {
        List {
            ForEach(journalDays) { day in
                Section {
                    ForEach(day.entryIDs, id: \.self) { entryID in
                        if let entry = entriesByID[entryID] {
                            journalRow(entry)
                        }
                    }
                } header: {
                    Text(day.label)
                        .font(.caption.weight(.semibold))
                        .tracking(1)
                        .foregroundStyle(AppTheme.workspaceMuted)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(AppTheme.workspaceBackground)
        .navigationTitle("Practice journal")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Practice journal")
                    .font(.system(.headline, design: .serif).weight(.semibold))
                    .foregroundStyle(AppTheme.workspaceInk)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button("New entry", systemImage: "plus") { showNewEntry = true }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.accentStrong)
                .frame(maxWidth: .infinity, minHeight: 44)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(AppTheme.workspacePanel)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if !networkMonitor.isOnline {
                OfflineHonestyBanner(pendingCount: syncManager.pendingQueueCount)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(AppTheme.workspaceBackground)
            }
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
        .sheet(isPresented: $showNewEntry) { NewEntryView(courseId: courseId) }
        .onChange(of: journalIndex, initial: true) { _, index in
            journalDays = JournalSectionPlanner.makeDays(from: index)
        }
    }

    private func journalRow(_ entry: LocalPracticeEntry) -> some View {
        NavigationLink(value: entry.id) {
            VStack(alignment: .leading, spacing: 7) {
                Text(entry.goalText)
                    .font(AppTheme.editorialGoal)
                    .foregroundStyle(AppTheme.workspaceInk)
                    .lineLimit(3)
                HStack(spacing: 0) {
                    Text(entry.practiceDate, style: .date)
                    if let duration = entry.durationSeconds, duration > 0 {
                        Text(" · \(formatDuration(duration))")
                    }
                    Spacer(minLength: 8)
                    StatusPill(status: entry.status.studentLifecycle(isRemoteBacked: entry.remoteUpdatedAt != nil))
                }
                .font(.caption)
                .foregroundStyle(AppTheme.workspaceMuted)
                if let feedback = entry.feedback.last, !feedback.commentsText.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(feedback.teacherName):")
                            .font(.caption.weight(.semibold))
                        Text(feedback.commentsText)
                            .font(.caption)
                            .lineLimit(2)
                    }
                    .foregroundStyle(AppTheme.workspaceInkSoft)
                    .padding(.top, 2)
                }
            }
            .padding(.vertical, 10)
            .frame(minHeight: 44, alignment: .leading)
            .overlay(alignment: .bottom) { WorkspaceRule() }
        }
        .accessibilityLabel("\(entry.goalText), \(entry.status.studentLifecycle(isRemoteBacked: entry.remoteUpdatedAt != nil).label)")
        .accessibilityHint("Opens this practice entry")
    }

    private var journalIndex: [JournalEntryIndex] {
        let calendar = Calendar.autoupdatingCurrent
        return entries.map {
            JournalEntryIndex(id: $0.id, day: calendar.startOfDay(for: $0.practiceDate))
        }
    }

    private var entriesByID: [String: LocalPracticeEntry] {
        Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
    }

    private func formatDuration(_ totalSeconds: Int) -> String {
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        return totalSeconds < 60 ? "\(totalSeconds)s" : "\(minutes) min"
    }
}

struct JournalEntryIndex: Equatable {
    let id: String
    let day: Date
}

struct JournalDay: Identifiable, Equatable {
    let date: Date
    let entryIDs: [String]
    var id: Date { date }

    var label: String {
        let calendar = Calendar.autoupdatingCurrent
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }
}

enum JournalSectionPlanner {
    static func makeDays(from index: [JournalEntryIndex]) -> [JournalDay] {
        Dictionary(grouping: index, by: \.day)
            .map { day, entries in
                JournalDay(date: day, entryIDs: entries.map(\.id))
            }
            .sorted { $0.date > $1.date }
    }
}
