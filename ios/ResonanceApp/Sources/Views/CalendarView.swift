import SwiftUI
import SwiftData

struct CalendarView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \CalendarEvent.startDate) private var events: [CalendarEvent]
    @StateObject private var calendarService = CalendarService()
    @State private var icalURLString: String = CalendarSubscriptionStore.load()
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack {
                Form {
                    Section("ASIMUT iCal URL") {
                        TextField("iCal URL", text: $icalURLString)
                            .accessibilityLabel("iCal URL")
                            .accessibilityHint("Enter your ASIMUT calendar URL")
                        Button("Save & Refresh") {
                            do {
                                try CalendarSubscriptionStore.save(icalURLString)
                                Task { await refresh() }
                            } catch {
                                errorMessage = error.localizedDescription
                            }
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
            .alert("Calendar refresh failed", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {
                    errorMessage = nil
                }
            } message: {
                Text(errorMessage ?? "Unknown error")
            }
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
        do {
            try await calendarService.refresh(from: url, modelContext: modelContext)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
