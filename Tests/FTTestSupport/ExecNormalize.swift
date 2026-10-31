// Port of tools/parity/exec/normalize.ts: turns an outcome as an engine recorded it (absolute temp
// paths, random hidden names and journal ids, file ids, dates) into what two runs of any engine
// share. The rules are listed in normalize.ts; exec/selftest.sh checks both give the same JSON.

public enum ExecNormalize {
    /// A place on disk and the token it becomes ("$ROOT", "$TRASH", ...).
    public struct Place: Codable, Sendable, Equatable {
        public var path: String
        public var token: String

        public init(path: String, token: String) {
            self.path = path
            self.token = token
        }
    }

    private static let droppedKeys: Set<String> = ["startedAt", "finishedAt"]
    private static let snapshotKeys = ["before", "after", "trash"]

    public static func outcome(_ value: JSONValue, places: [Place]) -> JSONValue {
        var walker = Walker(places: expand(places))
        var normalized = walker.walk(value)
        sortSnapshots(&normalized)
        if case .object(var members) = normalized, var recovery = members["recovery"] {
            sortSnapshots(&recovery)
            members["recovery"] = recovery
            normalized = .object(members)
        }
        return normalized
    }

    /// Each place also under its /var spelling when it is under /private/var, longest first.
    private static func expand(_ places: [Place]) -> [Place] {
        var all: [Place] = []
        for place in places {
            all.append(place)
            if place.path.hasPrefix("/private/") {
                all.append(Place(path: String(place.path.dropFirst("/private".count)), token: place.token))
            }
        }
        return all.sorted { a, b in
            let (x, y) = (a.path.utf16.count, b.path.utf16.count)
            return x != y ? x > y : a.path.utf16.lexicographicallyPrecedes(b.path.utf16)
        }
    }

    private static func sortSnapshots(_ value: inout JSONValue) {
        guard case .object(var members) = value else { return }
        for key in snapshotKeys {
            if case .array(let items) = members[key] {
                members[key] = .array(
                    items.sorted { a, b in
                        let (x, y) = (a["path"]?.stringValue ?? "undefined", b["path"]?.stringValue ?? "undefined")
                        return x.utf16.lexicographicallyPrecedes(y.utf16)
                    })
            }
        }
        value = .object(members)
    }

    private struct Ordinals {
        private var seen: [String: Int] = [:]

        mutating func of(_ key: String) -> Int {
            if let number = seen[key] {
                return number
            }
            let number = seen.count + 1
            seen[key] = number
            return number
        }
    }

    private struct Walker {
        let places: [(path: [UInt8], token: [UInt8])]
        var hidden = Ordinals()
        var journal = Ordinals()
        var question = Ordinals()
        var dev = Ordinals()
        var ino = Ordinals()

        init(places: [Place]) {
            self.places = places.map { (Array($0.path.utf8), Array($0.token.utf8)) }
        }

        mutating func walk(_ value: JSONValue) -> JSONValue {
            switch value {
            case .string(let text):
                return .string(self.text(text))
            case .array(let items):
                return .array(items.map { walk($0) })
            case .object(let members):
                var out: [String: JSONValue] = [:]
                for key in JSONValue.sortedKeys(members) where !droppedKeys.contains(key) {
                    if let child = members[key] {
                        out[key] = member(key, child)
                    }
                }
                return .object(out)
            default:
                return value
            }
        }

        private mutating func member(_ key: String, _ item: JSONValue) -> JSONValue {
            switch (key, item) {
            case ("mtimeMs", .int), ("mtimeMs", .double):
                return .string("set")
            case ("dev", .int), ("dev", .double), ("ino", .int), ("ino", .double):
                let number = item.description
                return .string("\(key)-\(key == "dev" ? dev.of(number) : ino.of(number))")
            case ("id", .string(let text)) where text.utf8.count == 16 && text.utf8.allSatisfy(Self.isHex):
                return .string("journal-\(journal.of(text))")
            case ("conflictId", .string(let text)):
                let counted = self.text(text)
                let digits = counted.utf8.reversed().prefix { $0 >= 0x30 && $0 <= 0x39 }.count
                let bytes = Array(counted.utf8)
                guard digits > 0, bytes.count > digits, bytes[bytes.count - digits - 1] == UInt8(ascii: "-") else {
                    return .string(counted)
                }
                let head = String(decoding: bytes[..<(bytes.count - digits - 1)], as: UTF8.self)
                let counter = String(decoding: bytes[(bytes.count - digits)...], as: UTF8.self)
                return .string("\(head)-q\(question.of(counter))")
            case ("analysisId", .string):
                return .string("analysis")
            case ("operationId", .string):
                return .string("operation")
            default:
                return walk(item)
            }
        }

        private static func isHex(_ byte: UInt8) -> Bool {
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x61 && byte <= 0x66)
        }

        /// Places replaced by their tokens wherever they occur, then hidden names' hex numbered.
        mutating func text(_ input: String) -> String {
            var bytes = Array(input.utf8)
            for place in places where !place.path.isEmpty {
                bytes = Self.replace(place.path, with: place.token, in: bytes)
            }
            return String(decoding: renameHidden(bytes), as: UTF8.self)
        }

        private static func replace(_ needle: [UInt8], with replacement: [UInt8], in bytes: [UInt8]) -> [UInt8] {
            guard bytes.count >= needle.count else { return bytes }
            var out: [UInt8] = []
            var index = 0
            while index < bytes.count {
                if index + needle.count <= bytes.count && bytes[index..<(index + needle.count)].elementsEqual(needle) {
                    out += replacement
                    index += needle.count
                } else {
                    out.append(bytes[index])
                    index += 1
                }
            }
            return out
        }

        /// `.filetrail-` and 8 hex digits not followed by another: the digits become "~<n>".
        private mutating func renameHidden(_ bytes: [UInt8]) -> [UInt8] {
            let marker = Array(".filetrail-".utf8)
            var out: [UInt8] = []
            var index = 0
            while index < bytes.count {
                let end = index + marker.count + 8
                if end <= bytes.count && bytes[index..<(index + marker.count)].elementsEqual(marker)
                    && bytes[(index + marker.count)..<end].allSatisfy(Self.isHex)
                    && (end == bytes.count || !Self.isHex(bytes[end]))
                {
                    let hex = String(decoding: bytes[(index + marker.count)..<end], as: UTF8.self)
                    out += marker + Array("~\(hidden.of(hex))".utf8)
                    index = end
                } else {
                    out.append(bytes[index])
                    index += 1
                }
            }
            return out
        }
    }
}
