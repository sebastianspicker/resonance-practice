// swift-tools-version: 6.2
// Defines the iOS executable target, bundled fixtures, and its test target.
import PackageDescription

let package = Package(
  name: "ResonanceApp",
  platforms: [.iOS(.v17)],
  products: [
    .executable(name: "ResonanceApp", targets: ["ResonanceApp"])
  ],
  targets: [
    .executableTarget(
      name: "ResonanceApp",
      path: "Sources",
      exclude: ["Resources/Info.plist"],
      resources: [.process("Resources/mock-university.json")]
    ),
    .testTarget(
      name: "ResonanceAppTests",
      dependencies: ["ResonanceApp"],
      path: "Tests"
    )
  ],
  swiftLanguageModes: [.v6]
)
