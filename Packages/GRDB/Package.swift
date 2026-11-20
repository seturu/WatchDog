// swift-tools-version:6.1
//
// VENDORED: GRDB.swift v7.12.0 (https://github.com/groue/GRDB.swift), with
// its SQLCipher build switched on, so WatchDog's usage history is encrypted
// on disk. GRDB only offers SQLCipher through the Swift Package Manager by
// editing this file, which is why a copy lives here.
//
// Differences from upstream: this manifest only (the "GRDB+SQLCipher" steps
// its comments describe, and no test target). GRDB/ and Sources/ are
// unmodified copies.
//
// To update: copy GRDB/, Sources/ and LICENSE from the new release over
// these, compare its Package.swift with this one, and run
//   swift test --package-path Packages/WatchDogCore

import PackageDescription

let package = Package(
    name: "GRDB",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15),
        .tvOS(.v13),
        .watchOS(.v7),
    ],
    products: [
        .library(name: "GRDB", targets: ["GRDB"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sqlcipher/SQLCipher.swift.git", from: "4.11.0"),
    ],
    targets: [
        .target(
            name: "GRDBSQLCipher",
            dependencies: [.product(name: "SQLCipher", package: "SQLCipher.swift")]
        ),
        .target(
            name: "GRDB",
            dependencies: [
                .product(name: "SQLCipher", package: "SQLCipher.swift"),
                .target(name: "GRDBSQLCipher"),
            ],
            path: "GRDB",
            resources: [.copy("PrivacyInfo.xcprivacy")],
            cSettings: [.define("SQLITE_HAS_CODEC")],
            swiftSettings: [
                .define("SQLITE_ENABLE_FTS5"),
                .define("SQLITE_ENABLE_SNAPSHOT"),
                .define("SQLITE_HAS_CODEC"),
                .define("SQLCipher"),
                .enableUpcomingFeature("MemberImportVisibility"),
            ]),
    ],
    swiftLanguageModes: [.v6]
)
