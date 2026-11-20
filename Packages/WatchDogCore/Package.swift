// swift-tools-version: 6.0
import PackageDescription

// Shared code for the app and the daemon, plus `wdprobe`, a command-line
// runner for the tracking probes:  swift run --package-path Packages/WatchDogCore wdprobe
// Tests:                            swift test --package-path Packages/WatchDogCore
let package = Package(
    name: "WatchDogCore",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "WatchDogCore", targets: ["WatchDogCore"]),
        .executable(name: "wdprobe", targets: ["wdprobe"]),
    ],
    dependencies: [
        // GRDB: a thin, well-documented layer over SQLite (think "query builder
        // plus migrations", not a full ORM). A vendored copy built against
        // SQLCipher, so the usage history is encrypted on disk: see the note
        // at the top of Packages/GRDB/Package.swift.
        .package(path: "../GRDB"),
    ],
    targets: [
        .target(name: "WatchDogCore",
                dependencies: [.product(name: "GRDB", package: "GRDB")],
                // The armed build is the release build. See Identifiers.swift and Limits.
                swiftSettings: [.define("ARMED", .when(configuration: .release))]),
        .executableTarget(name: "wdprobe", dependencies: ["WatchDogCore"]),
        .testTarget(name: "WatchDogCoreTests", dependencies: ["WatchDogCore"]),
    ]
)
