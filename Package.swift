// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FileTrail",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "FileTrail",
            path: "Sources/FileTrail"
        )
    ]
)
