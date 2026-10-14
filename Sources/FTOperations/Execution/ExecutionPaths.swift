// Node's `path.dirname` and `path.basename` (posix), as the paste engine of packages/core/src/fs/copyPasteExecution.ts
// calls them for every item it writes
import FTFoundation
import Foundation

/// `dirname(path)`: for the absolute paths without a trailing slash a paste works with, everything before the last
/// slash, found byte by byte (a paste of 100,000 items asks for it at each); `NodePath.dirname` for any other.
func dirnameOf(_ path: String) -> String {
    let bytes = path.utf8
    let slashByte = UInt8(ascii: "/")
    guard bytes.first == slashByte, let last = bytes.last, last != slashByte,
        let slash = bytes.lastIndex(of: slashByte)
    else {
        return NodePath.dirname(path)
    }
    if slash == bytes.startIndex {
        return "/"
    }
    // "//a" is "//"'s, as Node keeps a leading double slash.
    if bytes.index(after: bytes.startIndex) == slash {
        return NodePath.dirname(path)
    }
    return String(path[..<slash])
}

/// `basename(path)`: for a path without a trailing slash, everything after the last slash; `NodePath.basename` for
/// any other.
func basenameOf(_ path: String) -> String {
    let bytes = path.utf8
    let slashByte = UInt8(ascii: "/")
    guard let last = bytes.last, last != slashByte else {
        return NodePath.basename(path)
    }
    guard let slash = bytes.lastIndex(of: slashByte) else {
        return path
    }
    return String(path[bytes.index(after: slash)...])
}
