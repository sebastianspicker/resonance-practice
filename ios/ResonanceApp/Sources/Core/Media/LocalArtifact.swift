import Foundation
import SwiftData

@Model
final class LocalArtifact {
    @Attribute(.unique) var id: String
    var entryId: String
    @Relationship var entry: LocalPracticeEntry?
    var typeRaw: String
    var durationSeconds: Int
    var createdAt: Date
    var uploadStateRaw: String
    var syncPhaseRaw: String
    // Retained only for local-store compatibility; no longer written from the wire.
    var storageKey: String?
    var remoteUrl: String?
    var localPath: String

    init(id: String, entryId: String, type: ArtifactType, durationSeconds: Int, localPath: String) {
        self.id = id; self.entryId = entryId; self.typeRaw = type.rawValue; self.durationSeconds = durationSeconds
        self.createdAt = Date(); self.uploadStateRaw = UploadState.pending.rawValue; self.syncPhaseRaw = ArtifactSyncPhase.queued.rawValue
        self.storageKey = nil; self.remoteUrl = nil; self.localPath = localPath
    }

    var type: ArtifactType { get { ArtifactType(rawValue: typeRaw) ?? .audio } set { typeRaw = newValue.rawValue } }
    var uploadState: UploadState { get { UploadState(rawValue: uploadStateRaw) ?? .pending } set { uploadStateRaw = newValue.rawValue } }
    var syncPhase: ArtifactSyncPhase {
        get { ArtifactSyncPhase(rawValue: syncPhaseRaw) ?? .queued }
        set { syncPhaseRaw = newValue.rawValue }
    }
}
