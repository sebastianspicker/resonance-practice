import SwiftUI

// Stable navigation entrypoint for a selected practice entry.

struct EntryDetailView: View {
  let entry: LocalPracticeEntry
  private let initialSection: String?
  let showsArtifacts: Bool

  init(entry: LocalPracticeEntry, initialSection: String? = nil, showsArtifacts: Bool = true) {
    self.entry = entry
    self.initialSection = initialSection
    self.showsArtifacts = showsArtifacts
  }

  var body: some View {
    EntryDetailScreen(
      entry: entry,
      initialSection: initialSection,
      showsArtifacts: showsArtifacts
    )
  }
}
