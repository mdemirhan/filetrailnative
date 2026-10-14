// The collator behind JavaScript's localeCompare, which the original sorts names with
import Foundation

/// ICU's root collator with numeric ordering and primary strength: what
/// `a.localeCompare(b, undefined, { numeric: true, sensitivity: "base" })` compares with, in V8. The system's
/// ICU (libicucore) is looked up by name, as its headers are not in the SDK; where it is missing, names are
/// compared with `CollationTable` and Foundation instead.
struct ICUCollator: @unchecked Sendable {
    private typealias Open = @convention(c) (UnsafePointer<CChar>?, UnsafeMutablePointer<Int32>) -> OpaquePointer?
    private typealias SetAttribute = @convention(c) (OpaquePointer?, Int32, Int32, UnsafeMutablePointer<Int32>) -> Void
    private typealias GetSortKey =
        @convention(c) (OpaquePointer?, UnsafePointer<UInt16>?, Int32, UnsafeMutablePointer<UInt8>?, Int32) -> Int32

    // UCOL_NUMERIC_COLLATION and UCOL_STRENGTH are attributes; UCOL_ON and UCOL_PRIMARY their values.
    private static let numericCollation: Int32 = 7
    private static let strength: Int32 = 5
    private static let on: Int32 = 17
    private static let primary: Int32 = 0

    private let collator: OpaquePointer
    private let getSortKey: GetSortKey

    /// The collator, or nil where the system's ICU can't be used.
    static let shared: ICUCollator? = {
        guard let library = dlopen("/usr/lib/libicucore.dylib", RTLD_NOW),
            let openSymbol = dlsym(library, "ucol_open"), let attributeSymbol = dlsym(library, "ucol_setAttribute"),
            let sortKeySymbol = dlsym(library, "ucol_getSortKey")
        else { return nil }
        let open = unsafeBitCast(openSymbol, to: Open.self)
        let setAttribute = unsafeBitCast(attributeSymbol, to: SetAttribute.self)
        var status: Int32 = 0
        guard let collator = open("", &status), status <= 0 else { return nil }
        setAttribute(collator, numericCollation, on, &status)
        setAttribute(collator, strength, primary, &status)
        guard status <= 0 else { return nil }
        return ICUCollator(collator: collator, getSortKey: unsafeBitCast(sortKeySymbol, to: GetSortKey.self))
    }()

    /// Adds the sort key of `text` to `key`: comparing two keys byte by byte (`memcmp`, shorter first when
    /// one is the start of the other) orders the texts as the collator does.
    func appendSortKey(of text: String, to key: inout [UInt8]) {
        // A UTF-16 text is never longer than the UTF-8 one.
        let capacity = max(text.utf8.count, 1)
        withUnsafeTemporaryAllocation(of: UInt16.self, capacity: capacity) { units in
            var count = 0
            for unit in text.utf16 {
                units[count] = unit
                count += 1
            }
            appendSortKey(units: UnsafeBufferPointer(rebasing: units[..<count]), to: &key)
        }
    }

    private func appendSortKey(units: UnsafeBufferPointer<UInt16>, to key: inout [UInt8]) {
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 512) { buffer in
            let needed = Int(getSortKey(collator, units.baseAddress, Int32(units.count), buffer.baseAddress, 512))
            if needed <= 512 {
                key.append(contentsOf: UnsafeBufferPointer(rebasing: buffer[..<needed]))
                return
            }
            var larger = [UInt8](repeating: 0, count: needed)
            _ = larger.withUnsafeMutableBufferPointer {
                getSortKey(collator, units.baseAddress, Int32(units.count), $0.baseAddress, Int32(needed))
            }
            key.append(contentsOf: larger)
        }
    }
}
