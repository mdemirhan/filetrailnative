// Port of js_kind_for_path (packages/native-fs/src/native_thumbnail.m)
import CoreServices
import Foundation

/// What Finder shows in its Kind column for a file ("Markdown Document", "PNG image", "Plain Text
/// Document"). nil when there is none. Callers cache it per extension, since files with the same extension
/// share it.
public enum FileKind {
    /// The path buffer of the original; longer paths are cut there.
    static let maxPathBytes = 4095

    public static func kind(forPath path: String) -> String? {
        guard !path.isEmpty else { return nil }
        // The original reads the path into a 4096-byte buffer, which cuts a longer one.
        let path =
            path.utf8.count > maxPathBytes
            ? String(decoding: Array(path.utf8.prefix(maxPathBytes)), as: UTF8.self) : path
        // Spotlight's kind (kMDItemKind) is the one Finder's Kind column shows: "Markdown Document",
        // "Plain Text Document", where the type's own description is "Markdown" or "text". It is worked out
        // from the file when asked, indexed or not.
        if let item = MDItemCreate(kCFAllocatorDefault, path as CFString),
            let value = MDItemCopyAttribute(item, kMDItemKind) as? String, !value.isEmpty
        {
            return value
        }
        let url = URL(fileURLWithPath: path)
        // Then Launch Services' kind string, deprecated but without a replacement in the same words, then
        // the type's own description.
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
}
