// The names of an item's extended attributes, listed in one call: telling from it that an item has no tags, or no date
// last opened, costs about a third of asking for either (listxattr about 3.5 µs, getxattr 12 to 15 µs, warm, on an
// M-series Mac), and the list is read once for all of them.
import Darwin

enum ExtendedAttributes {
    /// The names of the item's attributes (a link itself is listed as it is followed, as `FinderTags` reads); nil when
    /// they can't be listed at once, as when the list is long, which leaves each attribute to be asked for.
    static func names(_ path: String) -> Set<String>? {
        withUnsafeTemporaryAllocation(byteCount: 1024, alignment: 1) { buffer in
            let length = listxattr(path, buffer.baseAddress, buffer.count, 0)
            if length < 0 { return errno == ENOTSUP ? [] : nil }
            let names = UnsafeRawBufferPointer(rebasing: buffer[..<length])
            return Set(names.split(separator: 0).map { String(decoding: $0, as: UTF8.self) })
        }
    }
}
