// Port of the parts of Node's path module (posix) that copyPasteNames.ts uses
import Foundation

/// `path.basename`, `dirname`, `extname` and `join` as Node's posix module answers them.
public enum NodePath {
    public static func basename(_ path: String) -> String {
        var scalars = Array(path.unicodeScalars)
        while scalars.count > 1 && scalars.last == "/" {
            scalars.removeLast()
        }
        if scalars == ["/"] { return "" }
        if let slash = scalars.lastIndex(of: "/") {
            scalars = Array(scalars[(slash + 1)...])
        }
        return scalarString(scalars)
    }

    public static func dirname(_ path: String) -> String {
        let scalars = Array(path.unicodeScalars)
        if scalars.isEmpty { return "." }
        let hasRoot = scalars[0] == "/"
        var end = -1
        var matchedSlash = true
        var index = scalars.count - 1
        while index >= 1 {
            if scalars[index] == "/" {
                if !matchedSlash {
                    end = index
                    break
                }
            } else {
                matchedSlash = false
            }
            index -= 1
        }
        if end == -1 { return hasRoot ? "/" : "." }
        if hasRoot && end == 1 { return "//" }
        return scalarString(Array(scalars[..<end]))
    }

    /// The last "." of the last part, and what follows; "" when it starts the part or there is none.
    public static func extname(_ path: String) -> String {
        let name = Array(basename(path).unicodeScalars)
        guard let dot = name.lastIndex(of: "."), dot > 0 else { return "" }
        if dot == 1 && name[0] == "." { return "" }
        return scalarString(Array(name[dot...]))
    }

    /// `path.resolve(path)` for an absolute path: normalized, without a trailing slash.
    public static func resolve(_ path: String) -> String {
        let normalized = normalize(path)
        var scalars = Array(normalized.unicodeScalars)
        while scalars.count > 1 && scalars.last == "/" {
            scalars.removeLast()
        }
        return scalarString(scalars)
    }

    public static func join(_ parts: String...) -> String {
        join(parts)
    }

    public static func join(_ parts: [String]) -> String {
        let joined = parts.filter { !$0.isEmpty }.joined(separator: "/")
        return joined.isEmpty ? "." : normalize(joined)
    }

    public static func normalize(_ path: String) -> String {
        let scalars = Array(path.unicodeScalars)
        if scalars.isEmpty { return "." }
        let isAbsolute = scalars[0] == "/"
        let trailingSlash = scalars.last == "/"
        var kept: [[Unicode.Scalar]] = []
        for part in scalars.split(separator: "/", omittingEmptySubsequences: true) {
            let part = Array(part)
            if part == ["."] { continue }
            if part == [".", "."] {
                if let last = kept.last, last != [".", "."] {
                    kept.removeLast()
                } else if !isAbsolute {
                    kept.append(part)
                }
                continue
            }
            kept.append(part)
        }
        var result: [Unicode.Scalar] = []
        for (index, part) in kept.enumerated() {
            if index > 0 { result.append("/") }
            result.append(contentsOf: part)
        }
        if result.isEmpty && !isAbsolute { result = ["."] }
        if !result.isEmpty && trailingSlash { result.append("/") }
        return (isAbsolute ? "/" : "") + scalarString(result)
    }

    private static func scalarString(_ scalars: [Unicode.Scalar]) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }
}
