// Golden files whose cases are written as changes to a base case's result
import Foundation

/// A golden file whose cases are written as changes to a base case's result, so what every case has in common (a new
/// command, a new preference, a new line of Help) is written once, in the base, and a case holds only what makes it
/// different. The file is `{"bases": {name: {"input", "output"}}, "cases": [{"name", "base"?, "input", "changes"}]}`;
/// a case names its base when the file has more than one, and a case with an "output" of its own is compared with it
/// whole. Each base is checked as a case of its own, and each case's changes applied to its base's output must give
/// the whole actual output, as a file of whole outputs would.
///
/// Changes, applied to a value:
/// - `{}` changes nothing;
/// - an object changes an object key by key: a key's change applied to that key's value (a key the value doesn't have
///   takes the change as it is), and `{"$delete": true}` removes the key;
/// - `{"$remove": [items], "$insert": [[after, item], …]}` changes a list: each item removed (its first equal
///   occurrence), then each item put after the first equal occurrence of `after`, or first when `after` is null, in
///   order, so one inserted can be the next one's `after`;
/// - `{"$set": value}`, or any other value (text, a number, true or false, null, a list), takes its place.
public enum GoldenChanges {
    struct Unreadable: Error, CustomStringConvertible {
        let description: String
    }

    /// The cases of `suite`, each with its whole expected output, the bases first.
    public static func load<Input: Decodable, Output: Decodable>(
        suite: String, in filePath: String = #filePath
    ) throws -> [GoldenCase<Input, Output>] {
        let data = try Data(contentsOf: Golden.url(suite: suite, in: filePath))
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let bases = root["bases"] as? [String: [String: Any]], let cases = root["cases"] as? [[String: Any]]
        else { throw Unreadable(description: "Golden/\(suite).json has no bases and cases") }
        var loaded: [GoldenCase<Input, Output>] = []
        for name in bases.keys.sorted() {
            guard let base = bases[name], let input = base["input"], let output = base["output"] else {
                throw Unreadable(description: "Golden/\(suite).json: base \(name) has no input or output")
            }
            loaded.append(GoldenCase(name: "base \(name)", input: try decode(input), output: try decode(output)))
        }
        for testCase in cases {
            let name = testCase["name"] as? String ?? "?"
            guard let input = testCase["input"] else {
                throw Unreadable(description: "Golden/\(suite).json: \(name) has no input")
            }
            let output: Any
            if let whole = testCase["output"] {
                output = whole
            } else {
                let baseName = testCase["base"] as? String ?? (bases.count == 1 ? bases.keys.first : nil)
                guard let baseName, let base = bases[baseName]?["output"] else {
                    throw Unreadable(description: "Golden/\(suite).json: \(name) names no base")
                }
                output = applying(testCase["changes"] ?? [String: Any](), to: base)
            }
            loaded.append(GoldenCase(name: name, input: try decode(input), output: try decode(output)))
        }
        return loaded
    }

    /// `change` applied to `base`, as this type's comment says.
    public static func applying(_ change: Any, to base: Any?) -> Any {
        guard let object = change as? [String: Any] else { return change }
        // No changes: the base as it is, a list as well as an object.
        if object.isEmpty, let base { return base }
        if let value = object["$set"] { return value }
        if object["$remove"] != nil || object["$insert"] != nil {
            return applyingToList(object, base as? [Any] ?? [])
        }
        guard var merged = base as? [String: Any] else { return object }
        for (key, value) in object {
            if let marker = value as? [String: Any], marker["$delete"] as? Bool == true {
                merged[key] = nil
            } else {
                merged[key] = applying(value, to: merged[key])
            }
        }
        return merged
    }

    private static func applyingToList(_ change: [String: Any], _ base: [Any]) -> [Any] {
        var list = base
        for item in change["$remove"] as? [Any] ?? [] {
            let text = canonical(item)
            if let at = list.firstIndex(where: { canonical($0) == text }) { list.remove(at: at) }
        }
        for pair in change["$insert"] as? [[Any]] ?? [] where pair.count == 2 {
            if pair[0] is NSNull {
                list.insert(pair[1], at: 0)
            } else {
                let text = canonical(pair[0])
                let at = list.firstIndex(where: { canonical($0) == text }).map { $0 + 1 } ?? list.count
                list.insert(pair[1], at: at)
            }
        }
        return list
    }

    /// One JSON text for a value, keys sorted, for comparing.
    static func canonical(_ value: Any) -> String {
        let data = try? JSONSerialization.data(
            withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "<not JSON>"
    }

    private static func decode<T: Decodable>(_ value: Any) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        return try JSONDecoder().decode(T.self, from: data)
    }
}
