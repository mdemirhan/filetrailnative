// Archives written by hand, for what the system's tools won't make: a device, a name twice, a link then an item
// through it, names that aren't UTF-8
import Foundation

/// A tar (ustar), one item after another in the order added.
struct TarBuilder {
    private var data = Data()

    /// What an item is, as a tar's header says it.
    enum Kind: UInt8 {
        case file = 0x30  // "0"
        case hardLink = 0x31
        case symlink = 0x32
        case characterDevice = 0x33
        case folder = 0x35
        case pipe = 0x36
    }

    /// Adds an item. `link`: what a link points to, as a path inside the tar for a hard link.
    mutating func add(
        _ name: String, _ kind: Kind = .file, mode: Int = 0o644, link: String = "", contents: String = "",
        modified: Int = 1_700_000_000
    ) {
        let body = kind == .file ? Array(contents.utf8) : []
        var header = [UInt8](repeating: 0, count: 512)
        func put(_ bytes: [UInt8], at offset: Int, room: Int) {
            precondition(bytes.count <= room, "too long for a tar header")
            header.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
        }
        func octal(_ value: Int, digits: Int) -> [UInt8] {
            let text = String(value, radix: 8)
            return Array((String(repeating: "0", count: digits - text.count) + text).utf8)
        }
        put(Array(name.utf8), at: 0, room: 100)
        put(octal(mode, digits: 7), at: 100, room: 8)
        put(octal(0, digits: 7), at: 108, room: 8)
        put(octal(0, digits: 7), at: 116, room: 8)
        put(octal(body.count, digits: 11), at: 124, room: 12)
        put(octal(modified, digits: 11), at: 136, room: 12)
        put([UInt8](repeating: 0x20, count: 8), at: 148, room: 8)
        header[156] = kind.rawValue
        put(Array(link.utf8), at: 157, room: 100)
        put(Array("ustar".utf8) + [0] + Array("00".utf8), at: 257, room: 8)
        put(octal(0, digits: 7), at: 329, room: 8)
        put(octal(0, digits: 7), at: 337, room: 8)
        let sum = header.reduce(0) { $0 + Int($1) }
        put(octal(sum, digits: 6) + [0, 0x20], at: 148, room: 8)
        data.append(contentsOf: header)
        data.append(contentsOf: body)
        data.append(contentsOf: [UInt8](repeating: 0, count: (512 - body.count % 512) % 512))
    }

    func write(to path: String) throws {
        try (data + Data(count: 1024)).write(to: URL(fileURLWithPath: path))
    }
}

/// A zip of files stored as they are, their names any bytes and not marked as UTF-8.
struct ZipBuilder {
    private var files = Data()
    private var directory = Data()
    private var count = 0

    private static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xEDB8_8320 : 0) }
        }
        return ~crc
    }

    private static func little(_ value: UInt32, _ bytes: Int) -> [UInt8] {
        (0..<bytes).map { UInt8((value >> (8 * UInt32($0))) & 0xFF) }
    }

    mutating func add(name: [UInt8], contents: String) {
        let body = Array(contents.utf8)
        let offset = UInt32(files.count)
        // Version 2.0, no flags, stored, a time and date (1 January 2024), then the checksum, sizes and name.
        let shared =
            Self.little(20, 2) + Self.little(0, 2) + Self.little(0, 2) + Self.little(0, 2) + Self.little(0x5821, 2)
            + Self.little(Self.checksum(body), 4) + Self.little(UInt32(body.count), 4)
            + Self.little(UInt32(body.count), 4) + Self.little(UInt32(name.count), 2) + Self.little(0, 2)
        files.append(contentsOf: Self.little(0x0403_4B50, 4) + shared + name + body)
        directory.append(
            contentsOf: Self.little(0x0201_4B50, 4) + Self.little(20, 2) + shared + Self.little(0, 2)
                + Self.little(0, 2) + Self.little(0, 2) + Self.little(0, 4) + Self.little(offset, 4) + name)
        count += 1
    }

    func write(to path: String) throws {
        let end =
            Self.little(0x0605_4B50, 4) + Self.little(0, 2) + Self.little(0, 2) + Self.little(UInt32(count), 2)
            + Self.little(UInt32(count), 2) + Self.little(UInt32(directory.count), 4)
            + Self.little(UInt32(files.count), 4) + Self.little(0, 2)
        try (files + directory + Data(end)).write(to: URL(fileURLWithPath: path))
    }
}
