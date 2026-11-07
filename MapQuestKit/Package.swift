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
    ],
    targets: [
        .target(
            name: "MapQuestCore",
            path: "Sources/MapQuestCore"
        ),
        .testTarget(
            name: "MapQuestCoreTests",
            dependencies: ["MapQuestCore"],
            path: "Tests/MapQuestCoreTests"
        ),
    ]
)
