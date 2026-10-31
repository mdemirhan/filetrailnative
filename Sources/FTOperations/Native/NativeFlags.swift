// Port of packages/native-fs/src/native_flags.c (nativeGetFlags, nativeSetFlags) and native_acl.c (nativeGetAcl,
// nativeSetAcl)
import Darwin
import Foundation

extension NativeFS {
    /// `nativeGetFlags(path)`: the item's BSD flags, `lstat` `st_flags` (a symlink is not followed).
    /// `UF_IMMUTABLE` is Finder's "Locked".
    public static func getFlags(_ path: String) throws -> UInt32 {
        var info = stat()
        if lstat(path, &info) != 0 {
            throw NativeError.errno(errno, syscall: "lstat", path: path)
        }
        return info.st_flags
    }

    /// `nativeSetFlags(path, flags)`: `lchflags(2)` (a symlink is not followed). Only the owner can change the
    /// user flags (UF_*); the system flags (SF_*) need root.
    public static func setFlags(_ path: String, _ flags: UInt32) throws {
        if lchflags(path, flags) != 0 {
            throw NativeError.errno(errno, syscall: "lchflags", path: path)
        }
    }

    /// `nativeGetAcl(path)`: the item's access control list as text (`acl_to_text`), nil when it has none.
    /// A symlink's own ACL is read, never its target's.
    public static func getAcl(_ path: String) throws -> String? {
        guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else {
            // ENOENT from acl_get_link_np also means an item with no ACL: told apart by looking for the item.
            let errnum = errno
            if errnum != ENOENT {
                throw NativeError.errno(errnum, syscall: "acl_get_link_np", path: path)
            }
            var item = stat()
            if lstat(path, &item) != 0 {
                throw NativeError.errno(errno, syscall: "lstat", path: path)
            }
            return nil
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard let text = acl_to_text(acl, nil) else {
            throw NativeError.errno(errno, syscall: "acl_to_text", path: path)
        }
        defer { acl_free(text) }
        return String(cString: text)
    }

    /// `nativeSetAcl(path, acl)`: gives the item the ACL `acl` (text from `getAcl`), or none at all for nil.
    /// A copy of ~/Documents carries its "group:everyone deny delete" entry, which keeps the Trash from taking
    /// it: Undo takes the entry off an item it made, and puts it back once the item is in the Trash.
    public static func setAcl(_ path: String, _ text: String?) throws {
        let made: acl_t? = if let text { acl_from_text(text) } else { acl_init(0) }
        guard let acl = made else {
            throw NativeError.errno(errno, syscall: text == nil ? "acl_init" : "acl_from_text", path: path)
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        if acl_set_link_np(path, ACL_TYPE_EXTENDED, acl) != 0 {
            throw NativeError.errno(errno, syscall: "acl_set_link_np", path: path)
        }
    }
}
