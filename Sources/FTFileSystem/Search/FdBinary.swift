import Foundation

/// The `fd` that ships with the app: Resources/fd in the repository, copied by scripts/build-app.sh into
/// Contents/Helpers/ and signed with the app.
public enum FdBinary {
    /// Resources/fd/manifest.json.
    public struct Manifest: Equatable, Sendable {
        public var tool: String
        public var version: String
        /// Under Resources/fd.
        public var relativeBinaryPath: String
    }

    public static let manifest = Manifest(
        tool: "fd", version: "10.5.0", relativeBinaryPath: "darwin-arm64/fd")

    public struct NotFound: Error, Equatable, CustomStringConvertible {
        public var description: String
    }

    /// Where the binary is looked for, in order: the app's Helpers folder, and the copy checked in beside the source
    /// (for tests and `swift run`, before an app is built).
    public struct Locations: Sendable {
        public var helpers: URL?
        public var sourceTree: URL?

        public init(helpers: URL?, sourceTree: URL?) {
            self.helpers = helpers
            self.sourceTree = sourceTree
        }

        /// The running app's, and the repository this file was built from.
        public static var standard: Locations {
            let bundle = Bundle.main.bundleURL
            let isApp = bundle.pathExtension == "app"
            return Locations(
                helpers: isApp ? bundle.appendingPathComponent("Contents/Helpers", isDirectory: true) : nil,
                sourceTree: repositoryRoot.appendingPathComponent("Resources/fd", isDirectory: true))
        }
    }

    /// Sources/FTFileSystem/Search/FdBinary.swift, four folders up.
    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    /// File Trail ships for Apple silicon only.
    public static func resolveBundledPath(
        locations: Locations = .standard,
        fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) throws -> String {
        var candidates: [URL] = []
        if let helpers = locations.helpers { candidates.append(helpers.appendingPathComponent("fd")) }
        if let sourceTree = locations.sourceTree {
            candidates.append(sourceTree.appendingPathComponent(manifest.relativeBinaryPath))
        }
        if let found = candidates.first(where: { fileExists($0.path) }) {
            return found.path
        }
        throw NotFound(description: "Bundled fd binary not found for \(currentArchitecture).")
    }

    public static var currentArchitecture: String {
        #if arch(arm64)
            "arm64"
        #else
            "unknown"
        #endif
    }
}
