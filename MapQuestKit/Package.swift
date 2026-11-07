// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MapQuestKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "MapQuestCore", targets: ["MapQuestCore"]),
        .library(name: "MapQuestSQLite", targets: ["MapQuestSQLite"]),
    ],
    targets: [
        // Apple platforms ship SQLite as the `SQLite3` module; elsewhere we link the system library.
        .systemLibrary(
            name: "CSQLite",
            path: "Sources/CSQLite",
            providers: [.apt(["libsqlite3-dev"])]
        ),
        // Clipper2 (Boost licence), vendored, behind a plain C interface.
        .target(
            name: "CClipper2",
            path: "Sources/CClipper2",
            exclude: ["clipper2/LICENSE", "clipper2/VENDORED.md"],
            sources: ["MQClipper.cpp", "clipper2/src"],
            publicHeadersPath: "include",
            cxxSettings: [.headerSearchPath("clipper2/include")]
        ),
        .target(
            name: "MapQuestCore",
            dependencies: ["CClipper2"],
            path: "Sources/MapQuestCore"
        ),
        .target(
            name: "MapQuestSQLite",
            dependencies: [
                "MapQuestCore",
                .target(name: "CSQLite", condition: .when(platforms: [.linux])),
            ],
            path: "Sources/MapQuestSQLite"
        ),
        // Shared contract tests that every MapQuestDataStore implementation must pass.
        .target(
            name: "MapQuestTestSupport",
            dependencies: ["MapQuestCore"],
            path: "Sources/MapQuestTestSupport"
        ),
        .testTarget(
            name: "MapQuestCoreTests",
            dependencies: ["MapQuestCore", "MapQuestTestSupport"],
            path: "Tests/MapQuestCoreTests"
        ),
        .testTarget(
            name: "MapQuestSQLiteTests",
            dependencies: ["MapQuestSQLite", "MapQuestCore", "MapQuestTestSupport"],
            path: "Tests/MapQuestSQLiteTests"
        ),
    ],
    cxxLanguageStandard: .cxx17
)
