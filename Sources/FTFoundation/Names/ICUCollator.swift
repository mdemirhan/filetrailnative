// The collator names are sorted with.
import Foundation

/// ICU's collator for a locale. The system's ICU (libicucore) is looked up by name, as its
/// headers are not in the SDK; where it is missing, `NameOrder` compares names as text by Foundation instead.
struct ICUCollator: @unchecked Sendable {
    private typealias Open = @convention(c) (UnsafePointer<CChar>?, UnsafeMutablePointer<Int32>) -> OpaquePointer?
    private typealias SetAttribute = @convention(c) (OpaquePointer?, Int32, Int32, UnsafeMutablePointer<Int32>) -> Void
    private typealias GetSortKey =
        @convention(c) (OpaquePointer?, UnsafePointer<UInt16>?, Int32, UnsafeMutablePointer<UInt8>?, Int32) -> Int32
    private typealias CompareUTF8 =
        @convention(c) (
            OpaquePointer?, UnsafePointer<CChar>?, Int32, UnsafePointer<CChar>?, Int32,
            UnsafeMutablePointer<Int32>
        ) -> Int32

    /// How much tells two texts apart: `primary`, letters alone (case and accents aside); `tertiary`, case and
    /// accents too, after the letters.
    enum Strength: Int32 {
        case primary = 0
        case tertiary = 2
    }

    // UCOL_NUMERIC_COLLATION and UCOL_STRENGTH are attributes; UCOL_ON a value.
    private static let numericCollation: Int32 = 7
    private static let strength: Int32 = 5
    private static let on: Int32 = 17

    private struct Library {
        let open: Open
        let setAttribute: SetAttribute
        let getSortKey: GetSortKey
        let compareUTF8: CompareUTF8
    }

    private static let library: Library? = {
        guard let library = dlopen("/usr/lib/libicucore.dylib", RTLD_NOW),
            let open = dlsym(library, "ucol_open"), let setAttribute = dlsym(library, "ucol_setAttribute"),
            let getSortKey = dlsym(library, "ucol_getSortKey"), let compareUTF8 = dlsym(library, "ucol_strcollUTF8")
        else { return nil }
        return Library(
            open: unsafeBitCast(open, to: Open.self), setAttribute: unsafeBitCast(setAttribute, to: SetAttribute.self),
            getSortKey: unsafeBitCast(getSortKey, to: GetSortKey.self),
            compareUTF8: unsafeBitCast(compareUTF8, to: CompareUTF8.self))
    }()

    private let collator: OpaquePointer
    private let library: Library

    /// The collator of `localeIdentifier` ("" for ICU's root, "sv_SE", …), or nil where the system's ICU can't be
    /// used. Made once per order and kept: opening one takes far longer than a comparison.
    /// `numeric`: numbers by value (2 before 10), not digit by digit.
    init?(localeIdentifier: String, strength: Strength, numeric: Bool) {
        guard let library = Self.library else { return nil }
        var status: Int32 = 0
        guard let collator = library.open(localeIdentifier, &status), status <= 0 else { return nil }
        if numeric { library.setAttribute(collator, Self.numericCollation, Self.on, &status) }
        library.setAttribute(collator, Self.strength, strength.rawValue, &status)
        guard status <= 0 else { return nil }
        self.collator = collator
        self.library = library
    }

    /// Negative, zero or positive as `left` comes before, with or after `right`.
    func compare(_ left: String, _ right: String) -> Int {
        var left = left
        var right = right
        var status: Int32 = 0
        let result = left.withUTF8 { a in
            right.withUTF8 { b in
                a.withMemoryRebound(to: CChar.self) { a in
                    b.withMemoryRebound(to: CChar.self) { b in
                        library.compareUTF8(
                            collator, a.baseAddress, Int32(a.count), b.baseAddress, Int32(b.count), &status)
                    }
                }
            }
        }
        return Int(result)
    }

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
            let needed = Int(
                library.getSortKey(collator, units.baseAddress, Int32(units.count), buffer.baseAddress, 512))
            if needed <= 512 {
                key.append(contentsOf: UnsafeBufferPointer(rebasing: buffer[..<needed]))
                return
            }
            var larger = [UInt8](repeating: 0, count: needed)
            _ = larger.withUnsafeMutableBufferPointer {
                library.getSortKey(collator, units.baseAddress, Int32(units.count), $0.baseAddress, Int32(needed))
            }
            key.append(contentsOf: larger)
        }
    }
}
