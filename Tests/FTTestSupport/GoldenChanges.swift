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
/// - `{"$set": value}`, or any other value (text, a number, true or false, null, a list), takes its place. An object
///   takes the place of a value that isn't one.
///
/// A change that can't mean what it says fails the file's load, with the file, the case and the place in its
/// changes, as a change passed over in silence leaves an expectation nobody wrote:
/// - `$remove` of an item the list doesn't have, and `$insert` after one it doesn't have;
/// - `$remove` that isn't a list, `$insert` that isn't a list of pairs `[after, item]`, and either of them applied to
///   a value that isn't a list;
/// - `$delete` of a key the value doesn't have, `$delete` with anything but `true`, and `$delete` where there is no
///   key to remove (a case's whole changes);
/// - `$set`, `$delete`, or `$remove` and `$insert`, with other keys beside them;
/// - any other key that starts with `$` (`$delet`), in a change or in an object taken as it is: no result has one.
public enum GoldenChanges {
    struct Unreadable: Error, CustomStringConvertible {
        let description: String
    }

    /// A change that can't be applied: where in the case's changes, and why.
    public struct Refused: Error, Equatable, CustomStringConvertible {
        public let place: String
        public let reason: String

        public init(place: String, reason: String) {
            self.place = place
            self.reason = reason
        }

        public var description: String { "\(place): \(reason)" }
    }

    /// The cases of `suite`, each with its whole expected output, the bases first.
    public static func load<Input: Decodable, Output: Decodable>(
        suite: String, in filePath: String = #filePath
    ) throws -> [GoldenCase<Input, Output>] {
        try load(suite: suite, from: Data(contentsOf: Golden.url(suite: suite, in: filePath)))
    }

    /// The cases in `data`, the text of the file `Golden/<suite>.json`.
    public static func load<Input: Decodable, Output: Decodable>(
        suite: String, from data: Data
    ) throws -> [GoldenCase<Input, Output>] {
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
                do {
                    output = try applying(testCase["changes"] ?? [String: Any](), to: base)
                } catch let refused as Refused {
                    throw Unreadable(description: "Golden/\(suite).json: \(name): \(refused)")
                }
            }
            loaded.append(GoldenCase(name: name, input: try decode(input), output: try decode(output)))
        }
        return loaded
    }

    /// `change` applied to `base`, as this type's comment says; `place` is where the change is in its case, for the
    /// error of one that is refused.
    public static func applying(_ change: Any, to base: Any?, at place: String = "changes") throws -> Any {
        guard let object = change as? [String: Any] else { return change }
        // No changes: the base as it is, a list as well as an object.
        if object.isEmpty, let base { return base }
        if let value = object["$set"] {
            try refuseOthers(than: ["$set"], in: object, at: place)
            return value
        }
        if object["$remove"] != nil || object["$insert"] != nil {
            try refuseOthers(than: ["$remove", "$insert"], in: object, at: place)
            guard let list = base as? [Any] else {
                throw Refused(place: place, reason: "$remove and $insert change a list, and \(named(base)) isn't one")
            }
            return try applyingToList(object, list, at: place)
        }
        if object["$delete"] != nil {
            throw Refused(place: place, reason: "$delete removes a key of an object, and there is none here")
        }
        guard var merged = base as? [String: Any] else {
            // Taken as it is, so nothing in it is read as a change: a `$` key there would become part of the result.
            if let stray = markerKey(in: object) {
                throw Refused(
                    place: place, reason: "\(stray) isn't read as a change in an object put in place of \(named(base))")
            }
            return object
        }
        // In the keys' order, so the same file always fails at the same place.
        for key in object.keys.sorted() {
            guard let value = object[key] else { continue }
            let inner = "\(place).\(key)"
            if key.hasPrefix("$") {
                throw Refused(place: inner, reason: "not a change: $set, $remove, $insert and $delete are")
            }
            if let marker = value as? [String: Any], let delete = marker["$delete"] {
                try refuseOthers(than: ["$delete"], in: marker, at: inner)
                guard isTrue(delete) else {
                    throw Refused(place: inner, reason: "$delete takes true, not \(canonical(delete))")
                }
                guard merged[key] != nil else {
                    throw Refused(place: inner, reason: "$delete of a key that isn't there")
                }
                merged[key] = nil
            } else {
                merged[key] = try applying(value, to: merged[key], at: inner)
            }
        }
        return merged
    }

    private static func applyingToList(_ change: [String: Any], _ base: [Any], at place: String) throws -> [Any] {
        var list = base
        if let remove = change["$remove"] {
            guard let items = remove as? [Any] else {
                throw Refused(place: "\(place).$remove", reason: "not a list of the items to remove")
            }
            for (index, item) in items.enumerated() {
                let text = canonical(item)
                guard let at = list.firstIndex(where: { canonical($0) == text }) else {
                    throw Refused(place: "\(place).$remove[\(index)]", reason: "\(text) isn't in the list")
                }
                list.remove(at: at)
            }
        }
        if let insert = change["$insert"] {
            guard let pairs = insert as? [Any] else {
                throw Refused(place: "\(place).$insert", reason: "not a list of pairs [after, item]")
            }
            for (index, each) in pairs.enumerated() {
                let inner = "\(place).$insert[\(index)]"
                guard let pair = each as? [Any], pair.count == 2 else {
                    throw Refused(place: inner, reason: "not a pair [after, item]")
                }
                if pair[0] is NSNull {
                    list.insert(pair[1], at: 0)
                } else {
                    let text = canonical(pair[0])
                    guard let at = list.firstIndex(where: { canonical($0) == text }) else {
                        throw Refused(place: inner, reason: "\(text), to insert after, isn't in the list")
                    }
                    list.insert(pair[1], at: at + 1)
                }
            }
        }
        return list
    }

    /// `$set`, `$delete`, and `$remove` with `$insert`, stand alone: a key beside them would be dropped unread.
    private static func refuseOthers(than allowed: Set<String>, in object: [String: Any], at place: String) throws {
        guard let other = object.keys.sorted().first(where: { !allowed.contains($0) }) else { return }
        let names = allowed.sorted().joined(separator: " and ")
        let verb = allowed.count > 1 ? "stand" : "stands"
        throw Refused(place: "\(place).\(other)", reason: "beside \(names), which \(verb) alone")
    }

    /// The first key that starts with `$` in an object, or in the objects and lists inside it.
    private static func markerKey(in value: Any) -> String? {
        if let object = value as? [String: Any] {
            for key in object.keys.sorted() {
                if key.hasPrefix("$") { return key }
                if let found = object[key].flatMap(markerKey) { return found }
            }
        } else if let list = value as? [Any] {
            for item in list {
                if let found = markerKey(in: item) { return found }
            }
        }
        return nil
    }

    /// JSON's `true` itself: a number 1 reads as a `Bool` too, and isn't it.
    private static func isTrue(_ value: Any) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
        return number.boolValue
    }

    /// What a value is, for an error: "a key that isn't there", "an object", "a list", or the value itself.
    private static func named(_ value: Any?) -> String {
        switch value {
        case nil: "a key that isn't there"
        case is [String: Any]: "an object"
        case is [Any]: "a list"
        case let value?: canonical(value)
        }
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
