import CoreServices
import Foundation

/// What Finder shows in its Kind column for a file ("Markdown Document", "PNG image", "Plain Text
/// Document"). nil when there is none. Callers cache it per extension, since files with the same extension
/// share it.
public enum FileKind {
    /// The longest path read, in bytes; longer paths are cut there.
    static let maxPathBytes = 4095

    public static func kind(forPath path: String) -> String? {
        guard let path = clipped(path) else { return nil }
        return spotlightKind(ofPath: path) ?? fallbackKind(ofPath: path)
    }

    static func clipped(_ path: String) -> String? {
        guard !path.isEmpty else { return nil }
        return path.utf8.count > maxPathBytes
            ? String(decoding: Array(path.utf8.prefix(maxPathBytes)), as: UTF8.self) : path
    }

    /// Spotlight's kind (kMDItemKind) is the one Finder's Kind column shows: "Markdown Document", "Plain Text
    /// Document", where the type's own description is "Markdown" or "text". It is worked out from the file when
    /// asked, indexed or not. nil for a file Spotlight cannot read.
    static func spotlightKind(ofPath path: String) -> String? {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString),
            let value = MDItemCopyAttribute(item, kMDItemKind) as? String, !value.isEmpty
        else { return nil }
        return value
    }

    /// Launch Services' kind string, deprecated but without a replacement in the same words, then the type's own
    /// description.
    private static func fallbackKind(ofPath path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        if let kind = launchServicesKind(of: url), !kind.isEmpty {
            return kind
        }
        if let description = try? url.resourceValues(forKeys: [.localizedTypeDescriptionKey])
            .localizedTypeDescription, !description.isEmpty
        {
            return description
        }
        return nil
    }

    private typealias CopyKindString = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFString>?>) -> Int32

    /// `LSCopyKindStringForURL`, looked up by name so the deprecation does not become a build warning.
    private static func launchServicesKind(of url: URL) -> String? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "LSCopyKindStringForURL") else {
            return nil
        }
        let copyKindString = unsafeBitCast(symbol, to: CopyKindString.self)
        var kind: Unmanaged<CFString>?
        guard copyKindString(url as CFURL, &kind) == 0, let kind else { return nil }
        return kind.takeRetainedValue() as String
    }

    /// Kinds asked of Spotlight once per content type. A file without an extension is typed by its name ("README",
    /// "Makefile"), its permissions (an executable) and Finder's type code, and Spotlight calls every file of one type
    /// the same; asking it costs most of a millisecond a file, finding the type a few hundredths. A file Spotlight
    /// cannot read gets the other words, as `kind(forPath:)` gives them, and they are not kept for its type.
    final class ByContentType: @unchecked Sendable {
        private let lock = NSLock()
        private var kinds: [String: String] = [:]

        func kind(forPath path: String) -> String? {
            guard let path = clipped(path) else { return nil }
            guard access(path, R_OK) == 0,
                let type = try? URL(fileURLWithPath: path, isDirectory: false)
                    .resourceValues(forKeys: [.contentTypeKey]).contentType?.identifier
            else { return FileKind.kind(forPath: path) }
            if let known = lock.withLock({ kinds[type] }) { return known }
            guard let spotlight = spotlightKind(ofPath: path) else { return fallbackKind(ofPath: path) }
            lock.withLock { kinds[type] = spotlight }
            return spotlight
        }
    }
}
