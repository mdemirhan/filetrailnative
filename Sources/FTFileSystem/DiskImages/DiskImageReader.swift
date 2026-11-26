import CFileTrail
import Compression
import Darwin
import FTFoundation
import Foundation

/// What a disk image says of itself, read from its own bytes, never by attaching it or asking hdiutil: its format, the
/// file systems on it, what it holds once mounted, and whether it is encrypted. Only what is known for certain is
/// said; anything else stays nil (a dash in the Info panel).
///
/// The kinds read: UDIF (.dmg with a "koly" trailer: its chunks stored as they are or compressed with zlib, bzip2,
/// LZFSE or LZMA), sparse images ("sprs"), sparse bundles, and raw images (a read/write .dmg, an .iso or .cdr). An
/// encrypted image ("encrcdsa", in the file or a sparse bundle's token) says only that. On the disk the image holds:
/// a GPT, Apple or MBR partition map (extended partitions too), or none; and APFS, Mac OS Extended (journaled,
/// case-sensitive), ExFAT, MS-DOS (FAT12, 16, 32), NTFS, ISO 9660 and UDF.
///
/// Images are often downloads, so nothing in one is trusted: every offset is checked against what is there, and a
/// table, a plist or a chunk larger than `limit` isn't read.
public enum DiskImageReader {
    /// The most read in one piece: a UDIF image's plist, one chunk, compressed or not, or a sparse bundle's plist.
    static let limit = 16 << 20

    /// The image at `path`, a file or a sparse bundle's folder; nil when it can't be read at all, or is kept only in
    /// the cloud, which reading would download.
    public static func read(_ path: String) -> InfoDetails.DiskImage? {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_flags & UInt32(SF_DATALESS) == 0 else { return nil }
        switch info.st_mode & S_IFMT {
        case S_IFDIR: return bundle(path)
        case S_IFREG: break
        default: return nil
        }
        // A segment of a split image holds part of a disk: nothing in it is read.
        if NodePath.extname(path).lowercased() == ".dmgpart" { return InfoDetails.DiskImage() }
        guard let file = ImageFile(path) else { return nil }
        let size = Int64(info.st_size)
        guard let head = file.read(0, 8), head.count == 8 else { return InfoDetails.DiskImage() }
        if head.starts(with: Array("encrcdsa".utf8)) { return InfoDetails.DiskImage(encrypted: true) }
        if head.starts(with: Array("sprs".utf8)) { return sparse(file) }
        if size >= 512, let tail = file.read(size - 512, 512), tail.starts(with: Array("koly".utf8)) {
            return udif(file, trailer: Bytes(tail), size: size)
        }
        // The disk's own bytes, read/write: said only when a disk is recognized in them, or they could be anything
        // (an encrypted image of a kind not read, say).
        let systems = DiskImageVolumes.fileSystems(file)
        guard let systems else { return InfoDetails.DiskImage() }
        let master = ["iso", "cdr", "toast", "dvdr"].contains(NodePath.extname(path).dropFirst().lowercased())
        return InfoDetails.DiskImage(
            format: master ? .cdMaster : .readWrite, fileSystems: systems, capacity: size, encrypted: false)
    }

    // MARK: Sparse images

    /// A sparse image: a 4,096-byte header (the band size and the disk's size, then a table of which band each place
    /// in the file holds), then the bands.
    private static func sparse(_ file: ImageFile) -> InfoDetails.DiskImage {
        var image = InfoDetails.DiskImage(format: .sparse, encrypted: false)
        guard let header = file.read(0, SparseImage.headerSize), header.count == SparseImage.headerSize else {
            return image
        }
        let bytes = Bytes(header)
        // The size in sectors: a 64-bit count at 28, which a 2 TB image needs; its 32-bit one at 16 for an image
        // that leaves that empty.
        let sectors64 = bytes.be64(28) ?? 0
        let sectors = sectors64 != 0 ? sectors64 : UInt64(bytes.be32(16) ?? 0)
        if sectors > 0, sectors < UInt64(Int64.max / 512) { image.capacity = Int64(sectors * 512) }
        if let sparse = SparseImage(file, header: bytes) {
            image.fileSystems = DiskImageVolumes.fileSystems(sparse) ?? []
        }
        return image
    }

    // MARK: UDIF

    /// A UDIF image: its disk in chunks, stored as they are or compressed, which a plist's tables place; a 512-byte
    /// trailer at its end says where the plist is and how many sectors the disk has.
    private static func udif(_ file: ImageFile, trailer: Bytes, size: Int64) -> InfoDetails.DiskImage {
        var image = InfoDetails.DiskImage(encrypted: false)
        if let sectors = trailer.be64(492), sectors > 0, sectors < UInt64(Int64.max / 512) {
            image.capacity = Int64(sectors * 512)
        }
        guard let udif = UDIFImage(file, trailer: trailer, size: size) else { return image }
        image.format = udif.compression.map { .compressed($0) } ?? .readOnly
        // A disk split over several files: this one holds only part of it.
        if (trailer.be32(60) ?? 0) <= 1 { image.fileSystems = DiskImageVolumes.fileSystems(udif) ?? [] }
        return image
    }

    // MARK: Sparse bundles

    /// A sparse bundle: Info.plist (the band size and the disk's size), and the bands, each a file in bands/ named in
    /// hexadecimal. Encrypted, its token file starts as an encrypted image does.
    private static func bundle(_ path: String) -> InfoDetails.DiskImage? {
        let plist = path + "/Info.plist"
        guard let data = ImageFile(plist)?.read(0, limit),
            let info = try? PropertyListSerialization.propertyList(from: Data(data), format: nil) as? [String: Any],
            info["diskimage-bundle-type"] as? String == "com.apple.diskimage.sparsebundle"
        else { return InfoDetails.DiskImage() }
        if let token = ImageFile(path + "/token")?.read(0, 8), token.starts(with: Array("encrcdsa".utf8)) {
            return InfoDetails.DiskImage(format: .sparseBundle, encrypted: true)
        }
        var image = InfoDetails.DiskImage(format: .sparseBundle, encrypted: false)
        let size = number(info["size"])
        if let size, size > 0 { image.capacity = size }
        if let size, let band = number(info["band-size"]), band > 0, band <= Int64(1 << 30) {
            image.fileSystems = DiskImageVolumes.fileSystems(SparseBundle(path: path, bandSize: band, size: size)) ?? []
        }
        return image
    }

    /// An integer of a plist, or a string of one.
    private static func number(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let text = value as? String { return Int64(text) }
        return nil
    }
}

// MARK: Reading

/// Where a disk's bytes come from: the image file as it is, or the pieces an image keeps it in.
protocol DiskBytes {
    /// `count` bytes from `offset` of the disk; nil where they can't be known (past its end, a chunk not read).
    func read(_ offset: Int64, _ count: Int) -> [UInt8]?
}

/// An image file, read with pread: the file stays closed between reads, so nothing is left open.
struct ImageFile: DiskBytes {
    let path: String

    init?(_ path: String) {
        guard access(path, R_OK) == 0 else { return nil }
        self.path = path
    }

    func read(_ offset: Int64, _ count: Int) -> [UInt8]? {
        guard offset >= 0, count >= 0, count <= DiskImageReader.limit else { return nil }
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var buffer = [UInt8](repeating: 0, count: count)
        var done = 0
        while done < count {
            let got = buffer.withUnsafeMutableBytes {
                pread(fd, $0.baseAddress! + done, count - done, off_t(offset) + off_t(done))
            }
            if got < 0, errno == EINTR { continue }
            guard got > 0 else { break }
            done += got
        }
        return done == count ? buffer : (done > 0 ? Array(buffer[..<done]) : nil)
    }
}

/// Big- and little-endian integers at an offset, nil past the end.
struct Bytes {
    let bytes: [UInt8]
    init(_ bytes: [UInt8]) { self.bytes = bytes }

    func be32(_ at: Int) -> UInt32? { word(at, 4, bigEndian: true).map { UInt32($0) } }
    func be64(_ at: Int) -> UInt64? { word(at, 8, bigEndian: true) }
    func le16(_ at: Int) -> UInt16? { word(at, 2, bigEndian: false).map { UInt16($0) } }
    func le32(_ at: Int) -> UInt32? { word(at, 4, bigEndian: false).map { UInt32($0) } }
    func le64(_ at: Int) -> UInt64? { word(at, 8, bigEndian: false) }
    func be16(_ at: Int) -> UInt16? { word(at, 2, bigEndian: true).map { UInt16($0) } }
    func byte(_ at: Int) -> UInt8? { at >= 0 && at < bytes.count ? bytes[at] : nil }

    /// Whether `text` is at `at`.
    func has(_ text: String, at: Int) -> Bool {
        let wanted = Array(text.utf8)
        guard at >= 0, at + wanted.count <= bytes.count else { return false }
        return bytes[at..<(at + wanted.count)].elementsEqual(wanted)
    }

    private func word(_ at: Int, _ size: Int, bigEndian: Bool) -> UInt64? {
        guard at >= 0, at + size <= bytes.count else { return nil }
        var value: UInt64 = 0
        for index in 0..<size {
            let byte = UInt64(bytes[bigEndian ? at + index : at + size - 1 - index])
            value = value << 8 | byte
        }
        return value
    }
}

/// A sparse image's disk: band `n` of the disk is wherever the header's table says, 4,096 bytes into the file and a
/// band per place. A band no place holds was never written, and reads as zeros, while the table has room for more;
/// once it is full, more of it is kept elsewhere in the file, which isn't read, and such a band is unknown.
struct SparseImage: DiskBytes {
    static let headerSize = 4096
    static let tableStart = 64
    let file: ImageFile
    let bandSize: Int64
    let size: Int64
    /// The place in the file of each band written.
    let places: [Int64: Int64]
    let tableFull: Bool

    init?(_ file: ImageFile, header: Bytes) {
        guard let sectorsPerBand = header.be32(8), sectorsPerBand > 0, sectorsPerBand <= 1 << 21 else { return nil }
        let sectors64 = header.be64(28) ?? 0
        let sectors = sectors64 != 0 ? sectors64 : UInt64(header.be32(16) ?? 0)
        guard sectors > 0, sectors < UInt64(Int64.max / 512) else { return nil }
        self.file = file
        bandSize = Int64(sectorsPerBand) * 512
        size = Int64(sectors) * 512
        var places: [Int64: Int64] = [:]
        var used = 0
        let count = (Self.headerSize - Self.tableStart) / 4
        for place in 0..<count {
            guard let band = header.be32(Self.tableStart + place * 4), band > 0 else { continue }
            used += 1
            places[Int64(band) - 1] = Int64(place)
        }
        self.places = places
        tableFull = used == count
    }

    func read(_ offset: Int64, _ count: Int) -> [UInt8]? {
        guard offset >= 0, count >= 0, offset + Int64(count) <= size else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(count)
        var at = offset
        while out.count < count {
            let band = at / bandSize
            let inner = at % bandSize
            let take = Int(min(Int64(count - out.count), bandSize - inner))
            if let place = places[band] {
                guard let piece = file.read(Int64(Self.headerSize) + place * bandSize + inner, take) else { return nil }
                out += piece
                // A band at the file's end may be shorter than the rest: what is past it was never written.
                if piece.count < take { out += [UInt8](repeating: 0, count: take - piece.count) }
            } else {
                guard !tableFull else { return nil }
                out += [UInt8](repeating: 0, count: take)
            }
            at += Int64(take)
        }
        return out
    }
}

/// A sparse bundle's disk: band `n` is the file bands/<n in hexadecimal>; a band with no file was never written.
struct SparseBundle: DiskBytes {
    let path: String
    let bandSize: Int64
    let size: Int64

    func read(_ offset: Int64, _ count: Int) -> [UInt8]? {
        guard offset >= 0, count >= 0, offset + Int64(count) <= size else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(count)
        var at = offset
        while out.count < count {
            let band = at / bandSize
            let inner = at % bandSize
            let take = Int(min(Int64(count - out.count), bandSize - inner))
            let bandPath = path + "/bands/" + String(band, radix: 16)
            var info = stat()
            if lstat(bandPath, &info) != 0 {
                out += [UInt8](repeating: 0, count: take)
            } else {
                // A band kept only in the cloud would be downloaded by reading it.
                guard info.st_flags & UInt32(SF_DATALESS) == 0, let file = ImageFile(bandPath) else { return nil }
                let piece = Int64(info.st_size) > inner ? (file.read(inner, take) ?? []) : []
                out += piece + [UInt8](repeating: 0, count: take - piece.count)
            }
            at += Int64(take)
        }
        return out
    }
}

/// A UDIF image's disk: the plist's "blkx" tables, one per partition, list the chunks it is kept in, each a run of
/// sectors stored as they are, compressed, or left out as zeros. A chunk that is read is decompressed whole, and kept
/// while the next reads are likely to fall in it.
final class UDIFImage: DiskBytes {
    struct Chunk {
        var start: Int64
        var length: Int64
        var kind: UInt32
        var fileOffset: Int64
        var fileLength: Int64
    }

    static let raw: UInt32 = 0x0000_0001
    static let zeros: Set<UInt32> = [0x0000_0000, 0x0000_0002]
    static let methods: [UInt32: String] = [
        0x8000_0004: "ADC", 0x8000_0005: "zlib", 0x8000_0006: "bzip2", 0x8000_0007: "LZFSE", 0x8000_0008: "LZMA",
    ]

    let file: ImageFile
    let chunks: [Chunk]
    /// How its chunks are compressed, the first method found; nil when none is.
    let compression: String?
    private var cached: (start: Int64, bytes: [UInt8])?

    init?(_ file: ImageFile, trailer: Bytes, size: Int64) {
        guard let plistOffset = trailer.be64(216), let plistLength = trailer.be64(224), plistLength > 0,
            plistLength <= UInt64(DiskImageReader.limit), plistOffset <= UInt64(size),
            plistOffset + plistLength <= UInt64(size), let data = file.read(Int64(plistOffset), Int(plistLength)),
            data.count == Int(plistLength),
            let plist = try? PropertyListSerialization.propertyList(from: Data(data), format: nil) as? [String: Any],
            let fork = plist["resource-fork"] as? [String: Any], let tables = fork["blkx"] as? [[String: Any]]
        else { return nil }
        var chunks: [Chunk] = []
        var compression: String?
        for table in tables {
            guard let data = table["Data"] as? Data else { continue }
            let bytes = Bytes([UInt8](data))
            guard bytes.has("mish", at: 0), let first = bytes.be64(8), let base = bytes.be64(24),
                let count = bytes.be32(200)
            else { continue }
            for index in 0..<Int(count) {
                let at = 204 + index * 40
                guard let kind = bytes.be32(at), let sector = bytes.be64(at + 8), let sectors = bytes.be64(at + 16),
                    let offset = bytes.be64(at + 24), let length = bytes.be64(at + 32)
                else { break }
                if kind == 0xFFFF_FFFF { break }
                guard sectors > 0, first < UInt64(Int64.max / 1024), sector < UInt64(Int64.max / 1024),
                    sectors < UInt64(Int64.max / 1024), base + offset < UInt64(Int64.max), length < UInt64(Int64.max)
                else { continue }
                if compression == nil, let method = Self.methods[kind] { compression = method }
                chunks.append(
                    Chunk(
                        start: Int64(first + sector) * 512, length: Int64(sectors) * 512, kind: kind,
                        fileOffset: Int64(base + offset), fileLength: Int64(length)))
            }
        }
        guard !chunks.isEmpty else { return nil }
        self.file = file
        self.chunks = chunks.sorted { $0.start < $1.start }
        self.compression = compression
    }

    func read(_ offset: Int64, _ count: Int) -> [UInt8]? {
        guard offset >= 0, count >= 0 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(count)
        var at = offset
        while out.count < count {
            guard let chunk = chunk(at) else { return nil }
            let inner = at - chunk.start
            let take = Int(min(Int64(count - out.count), chunk.length - inner))
            guard let bytes = bytes(of: chunk), Int64(bytes.count) >= inner + Int64(take) else { return nil }
            out += bytes[Int(inner)..<(Int(inner) + take)]
            at += Int64(take)
        }
        return out
    }

    private func chunk(_ offset: Int64) -> Chunk? {
        var low = 0
        var high = chunks.count - 1
        while low <= high {
            let middle = (low + high) / 2
            let chunk = chunks[middle]
            if offset < chunk.start {
                high = middle - 1
            } else if offset >= chunk.start + chunk.length {
                low = middle + 1
            } else {
                return chunk
            }
        }
        return nil
    }

    /// A chunk's sectors, whole.
    private func bytes(of chunk: Chunk) -> [UInt8]? {
        if let cached, cached.start == chunk.start { return cached.bytes }
        guard chunk.length <= Int64(DiskImageReader.limit) else { return nil }
        let length = Int(chunk.length)
        if Self.zeros.contains(chunk.kind) { return [UInt8](repeating: 0, count: length) }
        guard chunk.fileLength <= Int64(DiskImageReader.limit) else { return nil }
        let stored = chunk.kind == Self.raw ? length : Int(chunk.fileLength)
        guard let data = file.read(chunk.fileOffset, stored), data.count == stored else { return nil }
        let bytes: [UInt8]?
        switch chunk.kind {
        case Self.raw: bytes = data
        // zlib's two-byte header and its checksum around the deflate stream the framework reads.
        case 0x8000_0005: bytes = data.count > 2 ? Self.decode(Array(data[2...]), COMPRESSION_ZLIB, length) : nil
        case 0x8000_0006: bytes = Self.bunzip(data, length)
        case 0x8000_0007: bytes = Self.decode(data, COMPRESSION_LZFSE, length)
        case 0x8000_0008: bytes = Self.decode(data, COMPRESSION_LZMA, length)
        default: bytes = nil
        }
        guard let bytes, bytes.count == length else { return nil }
        cached = (chunk.start, bytes)
        return bytes
    }

    private static func decode(_ data: [UInt8], _ algorithm: compression_algorithm, _ length: Int) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: length)
        let written = out.withUnsafeMutableBufferPointer { target in
            data.withUnsafeBufferPointer { source in
                compression_decode_buffer(
                    target.baseAddress!, length, source.baseAddress!, data.count, nil, algorithm)
            }
        }
        return written == length ? out : nil
    }

    private static func bunzip(_ data: [UInt8], _ length: Int) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: length)
        var written = length
        let result = out.withUnsafeMutableBufferPointer { target in
            data.withUnsafeBufferPointer { source in
                ft_bunzip2(source.baseAddress, data.count, target.baseAddress, &written)
            }
        }
        return result == 0 && written == length ? out : nil
    }
}
