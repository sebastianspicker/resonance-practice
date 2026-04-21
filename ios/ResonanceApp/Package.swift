// swift-tools-version: 5.9
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
      resources: [.process("Resources/mock-university.json")]
    ),
    .testTarget(
      name: "ResonanceAppTests",
      dependencies: ["ResonanceApp"],
      path: "Tests"
    )
  ]
)
