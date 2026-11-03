// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Sideport",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "Sideport", path: "Sources/Sideport", linkerSettings: [.linkedLibrary("sqlite3")]),
    ]
)
