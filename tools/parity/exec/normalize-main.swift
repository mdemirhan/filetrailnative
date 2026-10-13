// The Swift side of selftest.sh's normalization check: normalizes a raw outcome (what
// `run.ts --raw` prints) with FTTestSupport.ExecNormalize and compares it with what normalize.ts
// made of the same one. Built by selftest.sh with swiftc together with
// Tests/FTTestSupport/{ExecJSON,ExecNormalize,JSONText}.swift.
// Usage: exec-normalize <raw.json> <normalized-by-bun.json>
import Foundation

@main
struct NormalizeMain {
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count == 3 else {
            FileHandle.standardError.write(Data("usage: exec-normalize <raw.json> <normalized.json>\n".utf8))
            exit(2)
        }
        do {
            let raw = try JSONValue.parse(Data(contentsOf: URL(fileURLWithPath: arguments[1])))
            let expected = try JSONValue.parse(Data(contentsOf: URL(fileURLWithPath: arguments[2])))
            let places = try (raw["places"] ?? .array([])).decode([ExecNormalize.Place].self)
            let normalized = ExecNormalize.outcome(raw["outcome"] ?? .null, places: places)
            let lines = ExecDiff.differences(expected: expected, actual: normalized)
            if !lines.isEmpty {
                print(lines.joined(separator: "\n"))
                exit(1)
            }
        } catch {
            FileHandle.standardError.write(Data("exec-normalize: \(error)\n".utf8))
            exit(1)
        }
    }
}
