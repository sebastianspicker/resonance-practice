import Foundation
import SwiftData

@Model
final class SyncQueueItem {
    @Attribute(.unique) var id: String; var type: String; var payloadJSON: String; var status: String; var retryCount: Int; var lastError: String?; var createdAt: Date; var nextAttemptAt: Date?; var ownerId: String
    init(id: String, type: String, payloadJSON: String, ownerId: String = "") {
        self.id = id; self.type = type; self.payloadJSON = payloadJSON; self.status = "pending"; self.retryCount = 0; self.lastError = nil; self.createdAt = Date(); self.nextAttemptAt = nil; self.ownerId = ownerId
    }
    var taskType: SyncTaskType? { SyncTaskType(rawValue: type) }
    var queueStatus: SyncStatus { get { SyncStatus(rawValue: status) ?? .pending } set { status = newValue.rawValue } }
}
