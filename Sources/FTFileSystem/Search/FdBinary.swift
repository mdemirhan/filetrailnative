// Port of apps/desktop/src/main/fdBinary.ts
import Foundation

/// The `fd` that ships with the app: Resources/fd in the repository, copied by scripts/build-app.sh into
/// Contents/Helpers/ and signed with the app.
public enum FdBinary {
    /// Resources/fd/manifest.json. The archive's SHA-256 is not verified at run time (it is only shown in About).
    public struct Manifest: Equatable, Sendable {
        public var tool: String
        public var version: String
        public var archiveSHA256: String
        /// Under Resources/fd.
        public var relativeBinaryPath: String
    }

    public static let manifest = Manifest(
        tool: "fd", version: "10.5.0",
        archiveSHA256: "b67e1836c468e42e411984b56e52fa7abec08c2bd22c867398e7cc134aac5e12",
        relativeBinaryPath: "darwin-arm64/fd")

    public struct NotFound: Error, Equatable, CustomStringConvertible {
        public var description: String
    }

    /// Where the binary is looked for, in order: the app's Helpers folder, the app's Resources/fd, and the copy checked
    /// in beside the source (for tests and `swift run`, before an app is built).
    public struct Locations: Sendable {
        public var helpers: URL?
        public var resources: URL?
        public var sourceTree: URL?

        public init(helpers: URL?, resources: URL?, sourceTree: URL?) {
            self.helpers = helpers
            self.resources = resources
            self.sourceTree = sourceTree
        }

        /// The running app's, and the repository this file was built from.
        public static var standard: Locations {
            let bundle = Bundle.main.bundleURL
            let isApp = bundle.pathExtension == "app"
            return Locations(
                helpers: isApp ? bundle.appendingPathComponent("Contents/Helpers", isDirectory: true) : nil,
                resources: isApp ? Bundle.main.resourceURL?.appendingPathComponent("fd", isDirectory: true) : nil,
                sourceTree: repositoryRoot.appendingPathComponent("Resources/fd", isDirectory: true))
        }
    }

    /// Sources/FTFileSystem/Search/FdBinary.swift, four folders up.
    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    /// `resolveBundledFdBinaryPath`. File Trail ships for Apple silicon only.
    public static func resolveBundledPath(
        arch: String = currentArchitecture, locations: Locations = .standard,
        fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) throws -> String {
        guard arch == "arm64" else {
            throw NotFound(description: "Unsupported macOS architecture for bundled fd: \(arch)")
        }
        var candidates: [URL] = []
        if let helpers = locations.helpers { candidates.append(helpers.appendingPathComponent("fd")) }
        for root in [locations.resources, locations.sourceTree] {
            if let root { candidates.append(root.appendingPathComponent(manifest.relativeBinaryPath)) }
        }
        if let found = candidates.first(where: { fileExists($0.path) }) {
            return found.path
        }
        throw NotFound(description: "Bundled fd binary not found for \(arch).")
    }

    public static var currentArchitecture: String {
        #if arch(arm64)
            "arm64"
        #elseif arch(x86_64)
            "x86_64"
        #else
            "unknown"
        #endif
    }
}
