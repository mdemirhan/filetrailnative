// Port of readAcknowledgements and resolveDistDir in apps/desktop/src/main/aboutInfo.ts (the list is made at build time
// by tools/acknowledgements, as scripts/thirdPartyLicenses.ts makes the original's)
import Foundation

/// One piece of bundled software and its license (`app:getAcknowledgements`).
public struct Acknowledgement: Equatable, Sendable {
    public var id: String
    public var name: String
    public var version: String?
    public var license: String
    public var url: String
    public var text: String

    public init(id: String, name: String, version: String?, license: String, url: String, text: String) {
        self.id = id
        self.name = name
        self.version = version
        self.license = license
        self.url = url
        self.text = text
    }
}

public enum Acknowledgements {
    /// Where the list is looked for: the app's `Resources/Acknowledgements`, and the copy checked in beside the source
    /// (for tests and `swift run`, before an app is built).
    public struct Locations: Sendable {
        public var resources: URL?
        public var sourceTree: URL?

        public init(resources: URL?, sourceTree: URL?) {
            self.resources = resources
            self.sourceTree = sourceTree
        }

        public static var standard: Locations {
            Locations(
                resources: Bundle.main.resourceURL?.appendingPathComponent("Acknowledgements", isDirectory: true),
                sourceTree: repositoryRoot.appendingPathComponent("Resources/Acknowledgements", isDirectory: true))
        }
    }

    /// Sources/FTFileSystem/AboutInfo/Acknowledgements.swift, four folders up.
    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    /// The first of the locations that holds an `index.json`; nil when none does.
    public static func resolveDirectory(_ locations: Locations = .standard) -> URL? {
        [locations.resources, locations.sourceTree].compactMap { $0 }.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("index.json").path)
        }
    }

    struct IndexEntry: Decodable {
        var id: String
        var name: String
        var version: String?
        var license: String
        var url: String
        var file: String
    }

    /// The bundled software in the build's order, each with the license text shipped beside it. Empty when the app
    /// carries no list.
    public static func read(_ locations: Locations = .standard) throws -> [Acknowledgement] {
        guard let directory = resolveDirectory(locations) else { return [] }
        let index = try JSONDecoder().decode(
            [IndexEntry].self, from: Data(contentsOf: directory.appendingPathComponent("index.json")))
        return try index.map { entry in
            Acknowledgement(
                id: entry.id, name: entry.name, version: entry.version, license: entry.license, url: entry.url,
                text: try String(contentsOf: directory.appendingPathComponent(entry.file), encoding: .utf8))
        }
    }
}
