import SwiftUI
import SwiftData

struct CalendarView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \CalendarEvent.startDate) private var events: [CalendarEvent]
    @StateObject private var calendarService = CalendarService()
    @State private var icalURLString: String = UserDefaults.standard.string(forKey: "icalURL") ?? ""

    var body: some View {
        NavigationStack {
            VStack {
                Form {
                    Section("ASIMUT iCal URL") {
                        TextField("iCal URL", text: $icalURLString)
                            .accessibilityLabel("iCal URL")
                            .accessibilityHint("Enter your ASIMUT calendar URL")
                        Button("Save & Refresh") {
                            UserDefaults.standard.set(icalURLString, forKey: "icalURL")
                            Task { await refresh() }
                        }
                        .accessibilityLabel("Save and refresh calendar")
                        .accessibilityHint("Double-tap to save the URL and reload calendar events")
                    }
                }

                List(events) { event in
                    VStack(alignment: .leading) {
                        Text(event.summary)
                        Text("\(event.startDate.formatted(date: .abbreviated, time: .shortened)) – \(event.endDate.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let location = event.location {
                            Text(location)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Calendar")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Refresh") { Task { await refresh() } }
                        .accessibilityLabel("Refresh calendar")
                        .accessibilityHint("Double-tap to reload calendar events")
                }
            }
        }
    }

    private func refresh() async {
        guard let url = URL(string: icalURLString), !icalURLString.isEmpty else { return }
        await calendarService.refresh(from: url, modelContext: modelContext)
    }
}
