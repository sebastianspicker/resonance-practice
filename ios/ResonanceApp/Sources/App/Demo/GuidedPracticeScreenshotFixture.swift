#if RESONANCE_SCREENSHOTS
import AVFoundation
import Foundation
import SwiftData

/// Materializes a local-only guided-practice state for deterministic screenshots.
/// The fixture is deliberately unavailable to normal application builds.
@MainActor
enum GuidedPracticeScreenshotFixture {
    private static let entryID = "demo_entry_lea_guided_practice"
    private static let artifactID = "demo_artifact_lea_guided_practice"
    private static let submissionID = "demo_submit_lea_guided_practice"
    private static let studentID = "demo_student_lea"
    private static let courseID = "demo_course_piano"

    static func prepare(scenario: ScreenshotScenario, modelContext: ModelContext) throws {
        let entry = LocalPracticeEntry(
            id: entryID,
            courseId: courseID,
            studentId: studentID,
            details: PracticeEntryDetails(
                practiceDate: fixtureDate,
                goalText: "Keep an even pulse in bars 17–24",
                durationSeconds: 1_200,
                tags: ["rhythm"],
                notes: "Left hand rushes when the melody enters."
            ),
            status: scenario.screen == .practiceSubmitted ? .submitted : .draft
        )
        entry.updatedAt = fixtureDate
        if scenario.screen == .practiceSubmitted {
            entry.remoteUpdatedAt = fixtureDate
            entry.serverVersion = 1
        }

        let audioURL = try writeTone(entryID: entryID)
        let artifact = LocalArtifact(
            id: artifactID,
            entryId: entryID,
            type: .audio,
            durationSeconds: 2,
            localPath: audioURL.path
        )
        artifact.createdAt = fixtureDate
        if scenario.screen == .practiceSubmitted {
            artifact.uploadState = .uploaded
            artifact.syncPhase = .uploaded
        }

        entry.artifacts.append(artifact)
        modelContext.insert(entry)
        modelContext.insert(artifact)

        if scenario.screen == .practiceQueued {
            let payloadJSON = try OutboxEnvelope(
                taskType: .submitEntry,
                payload: .entry(.init(entryId: entry.id))
            ).encodedJSON()
            let submission = SyncQueueItem(
                id: submissionID,
                type: SyncTaskType.submitEntry.rawValue,
                payloadJSON: payloadJSON,
                ownerId: studentID
            )
            submission.createdAt = fixtureDate
            modelContext.insert(submission)
        }

        try modelContext.save()
    }

    private static var fixtureDate: Date {
        Calendar(identifier: .gregorian).date(
            from: DateComponents(
                calendar: Calendar(identifier: .gregorian),
                timeZone: TimeZone(secondsFromGMT: 0),
                year: 2026,
                month: 9,
                day: 9,
                hour: 9
            )
        )!
    }

    private static func writeTone(entryID: String) throws -> URL {
        let url = FileStore.createAudioFileURL(entryId: entryID)
        let sampleRate = 44_100.0
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw FixtureError.audioFormatUnavailable
        }
        let frameCount = AVAudioFrameCount(sampleRate * 2)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let samples = buffer.floatChannelData?[0]
        else {
            throw FixtureError.audioBufferUnavailable
        }
        buffer.frameLength = frameCount
        for index in 0..<Int(frameCount) {
            let time = Double(index) / sampleRate
            let envelope = min(1, min(time * 20, (2 - time) * 20))
            samples[index] = Float(sin(2 * .pi * 440 * time) * 0.12 * envelope)
        }

        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: buffer)
        FileStore.setFileProtection(url: url)
        return url
    }

    private enum FixtureError: LocalizedError {
        case audioFormatUnavailable
        case audioBufferUnavailable

        var errorDescription: String? {
            switch self {
            case .audioFormatUnavailable: "Unable to configure screenshot audio."
            case .audioBufferUnavailable: "Unable to create screenshot audio."
            }
        }
    }
}
#endif
