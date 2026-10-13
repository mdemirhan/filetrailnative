import Foundation

/// Loads a file from `Tests/Golden/`, which lives outside every target, by path from this source file.
enum GoldenFile {
    static func json(_ name: String, filePath: String = #filePath) throws -> [String: Any] {
        let url = URL(fileURLWithPath: filePath)
            .deletingLastPathComponent()  // Design
            .deletingLastPathComponent()  // FTFoundationTests
            .deletingLastPathComponent()  // Tests
            .appendingPathComponent("Golden/\(name)")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        guard let dictionary = object as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return dictionary
    }
}
