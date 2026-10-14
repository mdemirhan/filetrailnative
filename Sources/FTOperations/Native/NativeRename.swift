// Port of packages/native-fs/src/native_rename.c (nativeRenameExclusive, nativeIsCaseSensitive,
// nativeUsesAppleDouble) and isAppleDoubleOnItsVolume, startsWithAppleDoubleMagic
// (packages/core/src/fs/writeServiceTypes.ts)
import Darwin
import FTFoundation
import Foundation

/// The system calls `renameExclusive` makes, replaceable to reach its fallback on any disk.
struct RenameCalls {
    var renamex: (String, String) -> Int32 = { renamex_np($0, $1, UInt32(RENAME_EXCL)) == 0 ? 0 : errno }
    var lstat: (String) -> Int32 = { path in
        var info = stat()
        return Darwin.lstat(path, &info) == 0 ? 0 : errno
    }
    var rename: (String, String) -> Int32 = { Darwin.rename($0, $1) == 0 ? 0 : errno }
}

extension NativeFS {
    /// `nativeRenameExclusive(from, to)`: `renamex_np(RENAME_EXCL)`, failing with EEXIST instead of replacing
    /// an item at `to`. A volume that can't do that (some network and FAT volumes, ENOTSUP) is checked first
    /// with `lstat`, then `rename(2)`. Errors name the syscall `rename`, `from` and `to`.
    public static func renameExclusive(_ from: String, _ to: String) throws {
        try renameExclusive(from, to, calls: RenameCalls())
    }

    static func renameExclusive(_ from: String, _ to: String, calls: RenameCalls) throws {
        let errnum = exclusiveRenameErrno(from, to, calls)
        if errnum != 0 {
            throw NativeError.errno(errnum, syscall: "rename", path: from, dest: to)
        }
    }

    private static func exclusiveRenameErrno(_ from: String, _ to: String, _ calls: RenameCalls) -> Int32 {
        let errnum = calls.renamex(from, to)
        guard errnum == ENOTSUP else { return errnum }
        // The volume can't do an exclusive rename. Checking first leaves a tiny window, but still never
        // replaces an item that was there before the move started. That window is a known, accepted limit:
        // an item made at `to` between the lstat and the rename is replaced. Such volumes offer no move that
        // refuses to replace (link(2) could do it for a file, but not for a folder).
        let found = calls.lstat(to)
        if found == 0 {
            return EEXIST
        }
        if found != ENOENT {
            return found
        }
        return calls.rename(from, to)
    }

    /// `nativeIsCaseSensitive(path)`: `pathconf(_PC_CASE_SENSITIVE)` for the volume holding `path`; nil when
    /// the volume doesn't say (EINVAL). Other failures (a missing path) throw, naming `pathconf`.
    public static func isCaseSensitive(_ path: String) throws -> Bool? {
        Darwin.errno = 0
        let answer = pathconf(path, _PC_CASE_SENSITIVE)
        if answer >= 0 {
            return answer > 0
        }
        let errnum = Darwin.errno
        if errnum == EINVAL {
            return nil
        }
        throw NativeError.errno(errnum, syscall: "pathconf", path: path)
    }

    /// `nativeUsesAppleDouble(path)`: whether the volume holding `path` keeps extended attributes in "._name"
    /// files (FAT, exFAT, some network volumes) rather than natively: `getattrlist` `VOL_CAP_INT_EXTENDED_ATTR`.
    /// nil when the volume doesn't say. Failures throw, naming `getattrlist`.
    public static func usesAppleDouble(_ path: String) throws -> Bool? {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.volattr = attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(ATTR_VOL_CAPABILITIES)
        // u_int32_t length, then vol_capabilities_attr_t.
        var buffer = [UInt32](repeating: 0, count: 1 + MemoryLayout<vol_capabilities_attr_t>.size / 4)
        let status = buffer.withUnsafeMutableBytes { bytes in
            getattrlist(path, &request, bytes.baseAddress, bytes.count, 0)
        }
        if status != 0 {
            throw NativeError.errno(Darwin.errno, syscall: "getattrlist", path: path)
        }
        let capabilities = buffer.withUnsafeBytes { bytes in
            bytes.load(fromByteOffset: 4, as: vol_capabilities_attr_t.self)
        }
        let interfaces = Int(VOL_CAPABILITIES_INTERFACES)
        let valid = withUnsafeBytes(of: capabilities.valid) { $0.load(fromByteOffset: interfaces * 4, as: UInt32.self) }
        let has = withUnsafeBytes(of: capabilities.capabilities) {
            $0.load(fromByteOffset: interfaces * 4, as: UInt32.self)
        }
        let flag = UInt32(VOL_CAP_INT_EXTENDED_ATTR)
        guard valid & flag != 0 else { return nil }
        // true: attributes live in "._name" files; false: the volume keeps them natively.
        return has & flag == 0
    }

    /// AppleDouble files begin with 0x00051607.
    static let appleDoubleMagic: [UInt8] = [0x00, 0x05, 0x16, 0x07]

    /// `startsWithAppleDoubleMagic(path)`: false when the file can't be read.
    public static func startsWithAppleDoubleMagic(_ path: String) -> Bool {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var header = [UInt8](repeating: 0, count: appleDoubleMagic.count)
        let read = header.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, $0.count, 0) }
        return read == header.count && header == appleDoubleMagic
    }

    /// `isAppleDoubleOnItsVolume(path)`: a "._name" file that macOS reads as "name"'s attributes, AppleDouble
    /// data on a disk that keeps attributes that way. Not when the disk keeps them natively or doesn't say.
    public static func isAppleDoubleOnItsVolume(
        _ path: String, usesAppleDouble: (String) throws -> Bool? = NativeFS.usesAppleDouble
    ) -> Bool {
        let answer = (try? usesAppleDouble(NodePath.dirname(path))) ?? nil
        return answer == true && startsWithAppleDoubleMagic(path)
    }
}
