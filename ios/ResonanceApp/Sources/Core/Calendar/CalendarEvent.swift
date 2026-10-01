import Foundation
import SwiftData

@Model
final class CalendarEvent {
    @Attribute(.unique) var id: String; var summary: String; var startDate: Date; var endDate: Date; var location: String?
    init(id: String, summary: String, startDate: Date, endDate: Date, location: String?) {
        self.id = id; self.summary = summary; self.startDate = startDate; self.endDate = endDate; self.location = location
    }
}
