// Port of the output readers in apps/desktop/src/main/diskImages.ts
import Foundation

/// What hdiutil printed. The original reads its plists with regular expressions; this parses them.
public enum HdiutilOutput {
    /// The values hdiutil's plist output gives a key, wherever it is in the plist.
    public static func strings(in plist: String, key: String) -> [String] {
        var found: [String] = []
        collect(parse(plist), key) { if let text = $0 as? String { found.append(text) } }
        return found
    }

    /// A boolean, or nil when the key isn't there.
    public static func boolean(in plist: String, key: String) -> Bool? {
        var found: Bool?
        collect(parse(plist), key) { value in
            if found == nil, CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() {
                found = (value as? Bool)
            }
        }
        return found
    }

    /// hdiutil says why it didn't attach on its last line: "hdiutil: attach failed - no mountable file
    /// systems", or "hdiutil: attach canceled" when a question went unanswered.
    public static func attachFailure(stderr: String) -> (canceled: Bool, reason: String?) {
        let lines = stderr.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.contains("WARNING") }
        if lines.contains(where: { $0.hasPrefix("hdiutil: attach canceled") }) {
            return (true, nil)
        }
        let prefix = "hdiutil: attach failed - "
        for line in lines.reversed() where line.hasPrefix(prefix) && line.count > prefix.count {
            return (false, String(line.dropFirst(prefix.count)))
        }
        return (false, nil)
    }

    private static func parse(_ plist: String) -> Any? {
        try? PropertyListSerialization.propertyList(from: Data(plist.utf8), options: [], format: nil)
    }

    /// Calls `found` with each value of `key`, in document order for arrays.
    private static func collect(_ node: Any?, _ key: String, _ found: (Any) -> Void) {
        if let dictionary = node as? [String: Any] {
            if let value = dictionary[key] { found(value) }
            for child in dictionary.keys.sorted().compactMap({ dictionary[$0] }) {
                collect(child, key, found)
            }
        } else if let array = node as? [Any] {
            for child in array { collect(child, key, found) }
        }
    }
}
