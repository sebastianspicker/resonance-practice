import Foundation
import SwiftData

// Loads and removes deterministic mock-university data for local demos and screenshots.

@MainActor
final class DemoDataManager {
    private let modelContext: ModelContext
    private let demoPrefix = "demo_"

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func loadMockUniversityData(roleInCourse: String = "student") throws {
        let fixture = try DemoDataFixtureLoader.load()
        try clearMockUniversityData()
        try DemoDataLoader(modelContext: modelContext).load(fixture, roleInCourse: roleInCourse)
    }

    func clearMockUniversityData() throws {
        try DemoDataCleanup(modelContext: modelContext, demoPrefix: demoPrefix).clear()
    }
}
