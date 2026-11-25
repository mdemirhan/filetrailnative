// What macOS keeps with a file that came from the internet: the quarantine mark, which asks before an app downloaded
// is first opened, and where it was downloaded from, as Get Info shows under "Where from".
import Darwin
import Foundation

enum DownloadMarks {
    /// Set by the app that downloaded the file (Safari, Mail, a browser); not by a tool that doesn't ask for it
    /// (`curl`), and taken off by `xattr -d`.
    static let quarantine = "com.apple.quarantine"
    /// The addresses the file was downloaded from: a binary property list of strings, the file's own address first.
    static let whereFrom = "com.apple.metadata:kMDItemWhereFroms"

    /// Whether the item at `path` has the quarantine mark, asked on its own: one that has its attribute names listed
    /// is told from them.
    static func isQuarantined(_ path: String) -> Bool {
        getxattr(path, quarantine, nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    /// The addresses the item at `path` was downloaded from; none for one that doesn't say.
    static func whereFroms(_ path: String) -> [String] {
        let size = getxattr(path, whereFrom, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0, size <= 1 << 20 else { return [] }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(path, whereFrom, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
        guard read == size else { return [] }
        let list = try? PropertyListSerialization.propertyList(from: data, format: nil)
        return (list as? [Any])?.compactMap { $0 as? String } ?? []
    }
}
