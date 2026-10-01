import Foundation

enum PracticeEntryStage {
  case record, reflect, check, receipt, details

  static func initial(for entry: LocalPracticeEntry, section: String?) -> Self {
    if section == "feedback" { return .details }
    if entry.status != .draft { return .receipt }
    if section == "guided-check" { return .check }
    return entry.artifacts.isEmpty || section == "guided-record" ? .record : .reflect
  }
}

/// Delivery state comes from durable work and authoritative entry status, never upload completion alone.
enum PracticeDeliveryState: Equatable {
  case unqueued, queued, sending, failed, submitted, reviewed

  static func resolve(
    status: EntryStatus, hasSubmission: Bool, hasFailure: Bool, isOnline: Bool
  ) -> Self {
    if status == .reviewed { return .reviewed }
    if status == .submitted { return .submitted }
    if hasFailure { return .failed }
    guard hasSubmission else { return .unqueued }
    return isOnline ? .sending : .queued
  }

  var title: String {
    switch self {
    case .unqueued: "Not submitted yet."
    case .queued: "Saved. Waiting to send."
    case .sending: "Sending for review."
    case .failed: "Your entry needs attention."
    case .submitted: "Submitted for review."
    case .reviewed: "Your feedback is here."
    }
  }

  var label: String {
    switch self {
    case .unqueued: "Private draft"
    case .queued: "Queued · not submitted"
    case .sending: "Sending · not submitted"
    case .failed: "Not submitted · action needed"
    case .submitted: "Submitted"
    case .reviewed: "Reviewed"
    }
  }

  var isConfirmed: Bool { self == .submitted || self == .reviewed }

  static func belongsToEntry(_ item: SyncQueueItem, entryID: String, ownerID: String) -> Bool {
    guard item.ownerId == ownerID, item.taskType == .submitEntry,
      let envelope = try? OutboxEnvelope.decode(payloadJSON: item.payloadJSON, taskType: .submitEntry)
    else { return false }
    return envelope.envelope.payload.entryID == entryID
  }
}
