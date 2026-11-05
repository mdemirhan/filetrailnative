import Foundation

public enum ApplicationPaths {
    /// Finder's application bundle. "Open With" passing this path means "Show in Finder".
    public static let finderAppPath = "/System/Library/CoreServices/Finder.app"

    /// An absolute path to a `.app` with no `..` part.
    public static func isValidBundlePath(_ applicationPath: String) -> Bool {
        let trimmed = trimmed(applicationPath)
        guard !trimmed.isEmpty, trimmed.hasPrefix("/") else { return false }
        if trimmed.split(separator: "/", omittingEmptySubsequences: false).contains("..") { return false }
        return normalize(trimmed).lowercased().hasSuffix(".app")
    }

    public static func invalidPathMessage(_ applicationPath: String) -> String {
        "Invalid application path: \(applicationPath). Expected an absolute path to a .app bundle."
    }

    /// The app's file name without `.app`.
    public static func displayName(_ applicationPath: String) -> String {
        let trimmed = trimmed(applicationPath)
        let bundleName = basename(trimmed)
        if bundleName.lowercased().hasSuffix(".app") {
            let name = String(bundleName.dropLast(4))
            return name.isEmpty ? trimmed : name
        }
        return bundleName.isEmpty ? trimmed : bundleName
    }

    /// Normalizes an absolute path: collapses repeated slashes and `.` parts; a trailing slash is kept.
    static func normalize(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." }
        var result = "/" + parts.joined(separator: "/")
        if path.hasSuffix("/") && result != "/" { result += "/" }
        return result
    }

    /// The last part of a path, trailing slashes ignored: "" for `/`.
    static func basename(_ path: String) -> String {
        var end = path.endIndex
        while end > path.startIndex, path[path.index(before: end)] == "/" { end = path.index(before: end) }
        return path[path.startIndex..<end].split(separator: "/").last.map(String.init) ?? ""
    }

    /// The path without its last part: `/` for a top-level item or `/` itself, `.` for a bare name.
    static func dirname(_ path: String) -> String {
        var end = path.endIndex
        while end > path.startIndex, path[path.index(before: end)] == "/" { end = path.index(before: end) }
        let trimmed = path[path.startIndex..<end]
        guard let slash = trimmed.lastIndex(of: "/") else { return trimmed.isEmpty && !path.isEmpty ? "/" : "." }
        var head = trimmed[trimmed.startIndex..<slash]
        while head.hasSuffix("/") { head = head.dropLast() }
        return head.isEmpty ? "/" : String(head)
    }

    /// The text without the whitespace and line terminators at either end.
    static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Copy Path: a path with whitespace is quoted for a shell, `'…'` with `'\''` for a quote inside.
public func formatPathForShell(_ path: String) -> String {
    guard path.unicodeScalars.contains(where: { $0.properties.isWhitespace }) else { return path }
    return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
