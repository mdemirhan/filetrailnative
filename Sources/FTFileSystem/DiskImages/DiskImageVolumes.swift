import FTFoundation
import Foundation

/// The file systems on a disk an image holds, named as Disk Utility names them, from the disk's partition map (GPT,
/// Apple's, MBR) or the file system at its start, and each file system's own signature. 512-byte sectors only.
enum DiskImageVolumes {
    /// The partitions followed at most, so a map that loops or lists thousands costs nothing.
    static let partitionLimit = 128

    /// The furthest a file system is looked for: far past any disk, and far enough from Int64.max that what is added
    /// to it (a CD's descriptors, an HFS catalog's place) can't overflow.
    static let offsetLimit = Int64(1) << 62

    /// The file systems recognized on the disk, each once, in the order of its partitions; nil when nothing on it is
    /// recognized, not even a partition map.
    static func fileSystems(_ disk: some DiskBytes) -> [String]? {
        guard let first = disk.read(0, 512).map(Bytes.init), first.bytes.count == 512 else { return nil }
        let second = disk.read(512, 512).map(Bytes.init)
        var names: [String]
        if let second, second.has("EFI PART", at: 0) {
            names = gpt(disk, header: second)
        } else if let found = fileSystem(disk, at: 0) {
            names = found
        } else if first.has("ER", at: 0), let second, second.has("PM", at: 0) {
            guard first.be16(2) == 512 else { return [] }
            names = apple(disk)
        } else if first.byte(510) == 0x55, first.byte(511) == 0xAA {
            names = mbr(disk, sector: first)
        } else {
            return nil
        }
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    // MARK: Partition maps

    /// The EFI System Partition: the firmware's, which a Mac disk carries beside its own.
    private static let efiSystem: [UInt8] = [
        0x28, 0x73, 0x2A, 0xC1, 0x1F, 0xF8, 0xD2, 0x11, 0xBA, 0x4B, 0x00, 0xA0, 0xC9, 0x3E, 0xC9, 0x3B,
    ]

    /// GPT (the UEFI specification): a header at sector 1 places the table of partitions, each with its type and its
    /// first sector.
    private static func gpt(_ disk: some DiskBytes, header: Bytes) -> [String] {
        guard let tableSector = header.le64(72), let count = header.le32(80), let size = header.le32(84),
            size >= 128, size <= 4096, tableSector < UInt64(Int64.max / 512)
        else { return [] }
        let entries = min(Int(count), partitionLimit)
        guard let table = disk.read(Int64(tableSector) * 512, entries * Int(size)).map(Bytes.init) else { return [] }
        var names: [String] = []
        for index in 0..<entries {
            let at = index * Int(size)
            guard at + 40 <= table.bytes.count else { break }
            let type = Array(table.bytes[at..<(at + 16)])
            guard type.contains(where: { $0 != 0 }), type != efiSystem, let start = table.le64(at + 32),
                start < UInt64(Int64.max / 512)
            else { continue }
            names += fileSystem(disk, at: Int64(start) * 512) ?? []
        }
        return names
    }

    /// Apple's partition map (Inside Macintosh): an entry per 512-byte block from block 1, "PM", the number of
    /// entries, the partition's first block and its type.
    private static func apple(_ disk: some DiskBytes) -> [String] {
        guard let first = disk.read(512, 512).map(Bytes.init), let count = first.be32(4) else { return [] }
        var names: [String] = []
        for block in 1...max(1, min(Int(count), partitionLimit)) {
            guard let entry = disk.read(Int64(block) * 512, 512).map(Bytes.init), entry.has("PM", at: 0),
                let start = entry.be32(8)
            else { break }
            if entry.has("Apple_partition_map", at: 48) || entry.has("Apple_Free", at: 48) { continue }
            names += fileSystem(disk, at: Int64(start) * 512) ?? []
        }
        return names
    }

    /// The MBR's four partitions, and the logical ones an extended partition chains.
    private static func mbr(_ disk: some DiskBytes, sector: Bytes) -> [String] {
        var names: [String] = []
        for index in 0..<4 {
            let at = 446 + index * 16
            guard let type = sector.byte(at + 4), let start = sector.le32(at + 8), type != 0, type != 0xEE else {
                continue
            }
            if [0x05, 0x0F, 0x85].contains(type) {
                names += logical(disk, extended: Int64(start))
            } else {
                names += fileSystem(disk, at: Int64(start) * 512) ?? []
            }
        }
        return names
    }

    /// An extended partition's chain: each link's first entry is a partition (from the link), its second the next
    /// link (from the extended partition's start).
    private static func logical(_ disk: some DiskBytes, extended: Int64) -> [String] {
        var names: [String] = []
        var link = extended
        for _ in 0..<partitionLimit {
            guard let sector = disk.read(link * 512, 512).map(Bytes.init), sector.byte(510) == 0x55,
                sector.byte(511) == 0xAA
            else { break }
            if let type = sector.byte(446 + 4), type != 0, let start = sector.le32(446 + 8) {
                names += fileSystem(disk, at: (link + Int64(start)) * 512) ?? []
            }
            guard let next = sector.le32(462 + 8), next != 0, sector.byte(462 + 4) != 0 else { break }
            let following = extended + Int64(next)
            guard following > link else { break }
            link = following
        }
        return names
    }

    // MARK: File systems

    /// The file system that starts at `offset`, by its own signature; nil when none is recognized. A CD or DVD's may
    /// be two at once (UDF with an ISO 9660 bridge).
    static func fileSystem(_ disk: some DiskBytes, at offset: Int64) -> [String]? {
        // A partition map can place a partition anywhere: one past `offsetLimit` is on no disk, and the places looked
        // at from it are sums that must stay within an Int64.
        guard offset >= 0, offset <= offsetLimit else { return nil }
        if let start = disk.read(offset, 2048).map(Bytes.init) {
            // APFS's container superblock: "NXSB" at 32 (Apple File System Reference).
            if start.has("NXSB", at: 32) { return ["APFS"] }
            if let name = hfs(disk, at: offset, header: start) { return [name] }
            if start.has("EXFAT   ", at: 3) { return ["ExFAT"] }
            if start.has("NTFS    ", at: 3) { return ["NTFS"] }
            if let fat = fat(start) { return ["MS-DOS (\(fat))"] }
        }
        return optical(disk, at: offset)
    }

    /// Mac OS Extended (Technical Note TN1150): the volume header at 1,024, "H+" or "HX" (HFSX), journaled when its
    /// attributes say so. HFSX is case-sensitive when its catalog compares names as binary.
    private static func hfs(_ disk: some DiskBytes, at offset: Int64, header: Bytes) -> String? {
        let base = 1024
        let isHFSX = header.has("HX", at: base)
        guard isHFSX || header.has("H+", at: base), let attributes = header.be32(base + 4) else { return nil }
        var traits: [String] = []
        if isHFSX, caseSensitive(disk, at: offset, header: header) { traits.append("Case-sensitive") }
        if attributes & (1 << 13) != 0 { traits.append("Journaled") }
        return traits.isEmpty ? "Mac OS Extended" : "Mac OS Extended (\(traits.joined(separator: ", ")))"
    }

    /// Whether an HFSX volume's catalog compares names as binary (0xBC), from the header record of its first node:
    /// the catalog's first extent is in the volume header.
    private static func caseSensitive(_ disk: some DiskBytes, at offset: Int64, header: Bytes) -> Bool {
        guard let blockSize = header.be32(1024 + 0x28), blockSize >= 512, blockSize <= 1 << 20,
            blockSize & (blockSize - 1) == 0, let startBlock = header.be32(1024 + 0x120),
            let node = disk.read(offset + Int64(startBlock) * Int64(blockSize), 64).map(Bytes.init)
        else { return false }
        // The node descriptor (14 bytes), then the header record, whose key compare type is at 37.
        return node.byte(14 + 37) == 0xBC
    }

    /// FAT12, FAT16 or FAT32, as Microsoft's specification tells them apart: by the number of clusters its boot
    /// sector's fields give, not by the label in it.
    static func fat(_ sector: Bytes) -> String? {
        guard sector.byte(510) == 0x55, sector.byte(511) == 0xAA,
            sector.byte(0) == 0xE9 || (sector.byte(0) == 0xEB && sector.byte(2) == 0x90),
            let bytesPerSector = sector.le16(11), [512, 1024, 2048, 4096].contains(bytesPerSector),
            let perCluster = sector.byte(13), perCluster > 0, perCluster & (perCluster - 1) == 0,
            let reserved = sector.le16(14), reserved > 0, let fats = sector.byte(16), fats > 0,
            let rootEntries = sector.le16(17), let total16 = sector.le16(19), let fatSize16 = sector.le16(22),
            let total32 = sector.le32(32), let fatSize32 = sector.le32(36)
        else { return nil }
        let fatSize = fatSize16 != 0 ? Int64(fatSize16) : Int64(fatSize32)
        let total = total16 != 0 ? Int64(total16) : Int64(total32)
        let rootSectors = (Int64(rootEntries) * 32 + Int64(bytesPerSector) - 1) / Int64(bytesPerSector)
        let data = total - (Int64(reserved) + Int64(fats) * fatSize + rootSectors)
        guard fatSize > 0, data > 0 else { return nil }
        let clusters = data / Int64(perCluster)
        return clusters < 4085 ? "FAT12" : clusters < 65525 ? "FAT16" : "FAT32"
    }

    /// A CD or DVD's (ECMA-119, ECMA-167): the volume descriptors from 32,768, 2,048 bytes each, name ISO 9660
    /// ("CD001") and UDF ("NSR02", "NSR03").
    private static func optical(_ disk: some DiskBytes, at offset: Int64) -> [String]? {
        var iso = false
        var udf = false
        for index in 0..<16 {
            guard let descriptor = disk.read(offset + 32768 + Int64(index) * 2048, 8).map(Bytes.init) else { break }
            if descriptor.has("CD001", at: 1) { iso = true }
            if descriptor.has("NSR02", at: 1) || descriptor.has("NSR03", at: 1) { udf = true }
            let known = ["CD001", "BEA01", "NSR02", "NSR03", "TEA01", "BOOT2", "CDW02"]
            if !known.contains(where: { descriptor.has($0, at: 1) }) { break }
        }
        let names = (udf ? ["UDF"] : []) + (iso ? ["ISO 9660"] : [])
        return names.isEmpty ? nil : names
    }
}
