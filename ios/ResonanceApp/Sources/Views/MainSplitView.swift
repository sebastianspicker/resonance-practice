import SwiftData
import SwiftUI

// Stable navigation entrypoint for the authenticated application shell.

struct MainSplitView: View {
  let modelContext: ModelContext

  var body: some View { MainSplitScreen(modelContext: modelContext) }
}
