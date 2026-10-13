// Golden files written by tools/parity/gen.sh from the reference app: Tests/Golden/<suite>.json.
import Foundation
import Testing

/// One recorded call of the reference: what went in and what came out.
public struct GoldenCase<Input, Output> {
    public let name: String
    public let input: Input
    public let output: Output

    public init(name: String, input: Input, output: Output) {
        self.name = name
        self.input = input
        self.output = output
    }
}

extension GoldenCase: Decodable where Input: Decodable, Output: Decodable {}
extension GoldenCase: Encodable where Input: Encodable, Output: Encodable {}
extension GoldenCase: Sendable where Input: Sendable, Output: Sendable {}

/// A whole golden file.
public struct GoldenFile<Input, Output> {
    public let suite: String
    public let referenceCommit: String
    public let seed: Int
    public let generator: String
    public let cases: [GoldenCase<Input, Output>]
}

extension GoldenFile: Decodable where Input: Decodable, Output: Decodable {}
extension GoldenFile: Encodable where Input: Encodable, Output: Encodable {}
extension GoldenFile: Sendable where Input: Sendable, Output: Sendable {}

public enum Golden {
    public struct NotFound: Error, CustomStringConvertible {
        public let suite: String
        public let from: String

        public var description: String {
            "no Golden/\(suite).json above \(from): run tools/parity/gen.sh \(suite)"
        }
    }

    /// Tests/Golden/<suite>.json, found from a test file's `#filePath` by walking up its folders.
    public static func url(suite: String, in filePath: String = #filePath) throws -> URL {
        var folder = URL(fileURLWithPath: filePath).deletingLastPathComponent()
        while folder.path != "/" {
            let candidate = folder.appendingPathComponent("Golden").appendingPathComponent("\(suite).json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            folder.deleteLastPathComponent()
        }
        throw NotFound(suite: suite, from: filePath)
    }

    public static func loadFile<Input: Decodable, Output: Decodable>(
        suite: String, in filePath: String = #filePath
    ) throws -> GoldenFile<Input, Output> {
        let data = try Data(contentsOf: url(suite: suite, in: filePath))
        return try JSONDecoder().decode(GoldenFile<Input, Output>.self, from: data)
    }

    public static func load<Input: Decodable, Output: Decodable>(
        suite: String, in filePath: String = #filePath
    ) throws -> [GoldenCase<Input, Output>] {
        let file: GoldenFile<Input, Output> = try loadFile(suite: suite, in: filePath)
        return file.cases
    }

    /// One line per case whose actual output differs from the recorded one, at most `limit` of them,
    /// after a count of all of them; nil when every case matches. Outputs are compared as JSON, so
    /// strings must match scalar for scalar (Swift's `==` would take NFC and NFD as equal).
    public static func mismatchReport<Input: Encodable, Output: Encodable>(
        _ cases: [GoldenCase<Input, Output>], limit: Int = 10, actual: (Input) throws -> Output
    ) rethrows -> String? {
        var lines: [String] = []
        var count = 0
        for testCase in cases {
            let expected = render(testCase.output)
            let got = render(try actual(testCase.input))
            // Byte for byte: `String`'s `==` takes NFC and NFD for equal.
            guard !expected.utf8.elementsEqual(got.utf8) else { continue }
            count += 1
            if lines.count < limit {
                lines.append("\(testCase.name) | input: \(render(testCase.input)) | expected: \(expected) | actual: \(got)")
            }
        }
        guard count > 0 else { return nil }
        let header = "\(count) of \(cases.count) golden cases differ" + (count > limit ? "; the first \(limit):" : ":")
        return ([header] + lines).joined(separator: "\n")
    }

    /// Records one issue listing the first 10 mismatching cases, if any.
    public static func expectMatches<Input: Encodable, Output: Encodable>(
        _ cases: [GoldenCase<Input, Output>], sourceLocation: SourceLocation = #_sourceLocation,
        actual: (Input) throws -> Output
    ) rethrows {
        if let report = try mismatchReport(cases, actual: actual) {
            Issue.record(Comment(rawValue: report), sourceLocation: sourceLocation)
        }
    }

    /// Compact JSON with sorted keys, for comparing and printing.
    public static func render(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "<not encodable>" }
        return String(decoding: data, as: UTF8.self)
    }
}
