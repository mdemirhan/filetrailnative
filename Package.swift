// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FileTrail",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CFileTrail", path: "Sources/CFileTrail"),
        .target(name: "FTFoundation", path: "Sources/FTFoundation"),
        .target(name: "FTFileSystem", dependencies: ["FTFoundation", "CFileTrail"], path: "Sources/FTFileSystem"),
        .target(
            name: "FTOperations", dependencies: ["FTFoundation", "FTFileSystem", "CFileTrail"],
            path: "Sources/FTOperations"),
        .target(
            name: "FTAppKit", dependencies: ["FTFoundation", "FTFileSystem", "FTOperations", "CFileTrail"],
            path: "Sources/FTAppKit"),
        .executableTarget(name: "FileTrail", dependencies: ["FTAppKit"], path: "Sources/FileTrail"),
        // Golden files, tree snapshots and temp folders for the tests (see CLAUDE.md).
        .target(name: "FTTestSupport", path: "Tests/FTTestSupport"),
        .testTarget(
            name: "FTFoundationTests", dependencies: ["FTFoundation", "FTTestSupport"], path: "Tests/FTFoundationTests"),
        .testTarget(
            name: "FTFileSystemTests", dependencies: ["FTFileSystem", "FTFoundation", "FTTestSupport"],
            path: "Tests/FTFileSystemTests",
            // Budgets hold only when optimized; tools/bench/listing.sh also defines DEBUG for FTAppKitTests to compile.
            swiftSettings: [.define("RELEASE", .when(configuration: .release))]),
        .testTarget(
            name: "FTOperationsTests", dependencies: ["FTOperations", "FTFoundation", "FTTestSupport"],
            path: "Tests/FTOperationsTests"),
        .testTarget(name: "FTAppKitTests", dependencies: ["FTAppKit", "FTFoundation", "FTTestSupport"], path: "Tests/FTAppKitTests"),
    ]
)
