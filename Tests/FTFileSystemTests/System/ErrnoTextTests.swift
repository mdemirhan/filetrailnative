import Darwin
import Foundation
import Testing

@testable import FTFileSystem

/// The name each system error number is shown with, and the text of each error that shows one. Recorded from the app as
/// it was, number by number, so the names and texts stay what users have seen.
@Suite struct ErrnoTextTests {
    /// Every number that has a name; any other has none.
    static let names: [Int32: String] = [
        1: "EPERM", 2: "ENOENT", 3: "ESRCH", 4: "EINTR", 5: "EIO", 6: "ENXIO",
        7: "E2BIG", 8: "ENOEXEC", 9: "EBADF", 10: "ECHILD", 11: "EDEADLK", 12: "ENOMEM",
        13: "EACCES", 14: "EFAULT", 15: "ENOTBLK", 16: "EBUSY", 17: "EEXIST", 18: "EXDEV",
        19: "ENODEV", 20: "ENOTDIR", 21: "EISDIR", 22: "EINVAL", 23: "ENFILE", 24: "EMFILE",
        25: "ENOTTY", 26: "ETXTBSY", 27: "EFBIG", 28: "ENOSPC", 29: "ESPIPE", 30: "EROFS",
        31: "EMLINK", 32: "EPIPE", 33: "EDOM", 34: "ERANGE", 35: "EAGAIN", 36: "EINPROGRESS",
        37: "EALREADY", 38: "ENOTSOCK", 39: "EDESTADDRREQ", 40: "EMSGSIZE", 41: "EPROTOTYPE", 42: "ENOPROTOOPT",
        43: "EPROTONOSUPPORT", 44: "ESOCKTNOSUPPORT", 45: "ENOTSUP", 46: "EPFNOSUPPORT", 47: "EAFNOSUPPORT",
        48: "EADDRINUSE", 49: "EADDRNOTAVAIL", 50: "ENETDOWN", 51: "ENETUNREACH", 52: "ENETRESET",
        53: "ECONNABORTED", 54: "ECONNRESET", 55: "ENOBUFS", 56: "EISCONN", 57: "ENOTCONN", 58: "ESHUTDOWN",
        59: "ETOOMANYREFS", 60: "ETIMEDOUT", 61: "ECONNREFUSED", 62: "ELOOP", 63: "ENAMETOOLONG", 64: "EHOSTDOWN",
        65: "EHOSTUNREACH", 66: "ENOTEMPTY", 67: "EPROCLIM", 68: "EUSERS", 69: "EDQUOT", 70: "ESTALE",
        71: "EREMOTE", 72: "EBADRPC", 73: "ERPCMISMATCH", 74: "EPROGUNAVAIL", 75: "EPROGMISMATCH",
        76: "EPROCUNAVAIL", 77: "ENOLCK", 78: "ENOSYS", 79: "EFTYPE", 80: "EAUTH", 81: "ENEEDAUTH", 82: "EPWROFF",
        83: "EDEVERR", 84: "EOVERFLOW", 85: "EBADEXEC", 86: "EBADARCH", 87: "ESHLIBVERS", 88: "EBADMACHO",
        89: "ECANCELED", 90: "EIDRM", 91: "ENOMSG", 92: "EILSEQ", 93: "ENOATTR", 94: "EBADMSG",
        95: "EMULTIHOP", 96: "ENODATA", 97: "ENOLINK", 98: "ENOSR", 99: "ENOSTR", 100: "EPROTO",
        101: "ETIME", 102: "EOPNOTSUPP", 103: "ENOPOLICY", 104: "ENOTRECOVERABLE", 105: "EOWNERDEAD",
        106: "EQFULL",
    ]

    /// How a folder that can't be listed begins its message, for the numbers it names.
    static let listingTexts: [Int32: String] = [
        1: "EPERM: operation not permitted",
        2: "ENOENT: no such file or directory",
        5: "EIO: i/o error",
        6: "ENXIO: device not configured",
        9: "EBADF: bad file descriptor",
        12: "ENOMEM: not enough memory",
        13: "EACCES: permission denied",
        14: "EFAULT: bad address",
        16: "EBUSY: resource busy or locked",
        17: "EEXIST: file exists",
        18: "EXDEV: cross-device link",
        19: "ENODEV: operation not supported by device",
        20: "ENOTDIR: not a directory",
        21: "EISDIR: is a directory",
        22: "EINVAL: invalid argument",
        23: "ENFILE: too many open files in system",
        24: "EMFILE: too many open files",
        28: "ENOSPC: no space left on device",
        30: "EROFS: read-only file system",
        45: "ENOTSUP: operation not supported on socket",
        60: "ETIMEDOUT: connection timed out",
        62: "ELOOP: too many symbolic links encountered",
        63: "ENAMETOOLONG: name too long",
        66: "ENOTEMPTY: directory not empty",
        84: "EOVERFLOW: value too large to be stored in data type",
        89: "ECANCELED: operation canceled",
    ]

    static let numbers = Int32(-5)..<Int32(1000)

    @Test func everyNumberHasItsName() {
        for number in Self.numbers {
            #expect(Errno.name(of: number) == Self.names[number], "\(number)")
            #expect(Errno.nameOrUnknown(of: number) == Self.names[number] ?? "UNKNOWN", "\(number)")
        }
    }

    @Test func aFolderThatCantBeListedSaysWhy() {
        for number in Self.numbers {
            let text = ExplorerError.system(code: number, path: "/x").description
            if let start = Self.listingTexts[number] {
                #expect(text == "\(start), scandir '/x'")
            } else if let name = Self.names[number] {
                // Named by the same table as every other error, in the system's words.
                let words = String(cString: strerror(number))
                #expect(text == "\(name): \(words.prefix(1).lowercased())\(words.dropFirst()), scandir '/x'")
            } else {
                #expect(text == "Unknown system error -\(number): Unknown system error -\(number), scandir '/x'")
            }
        }
    }

    // A stale network volume and a full quota were "Unknown system error -70" and "-69".
    @Test func aFolderOnAStaleNetworkVolumeOrPastItsQuotaSaysSo() {
        #expect(
            ExplorerError.system(code: ESTALE, path: "/x").description == "ESTALE: stale NFS file handle, scandir '/x'")
        #expect(
            ExplorerError.system(code: EDQUOT, path: "/x").description == "EDQUOT: disc quota exceeded, scandir '/x'")
    }

    @Test func aSearchThatCantStartNamesItsError() {
        for number in Self.numbers {
            #expect(FdProcess.errnoName(number) == Self.names[number] ?? "errno \(number)")
        }
    }

    @Test func aFailedEjectNamesItsError() {
        let volume = Volume(
            path: "/Volumes/USB", name: "USB", isLocal: true, isReadOnly: false, fileSystem: "apfs", canEject: true,
            disk: "disk4")
        for number in Self.numbers where ![ETIMEDOUT, EPERM, EACCES].contains(number) {
            let notice = EjectPlanning.describeEjectFailure(
                [volume], path: "/Volumes/USB", failedPath: nil, errnum: number, reason: nil)
            #expect(notice.message == "An unexpected error occurred (\(Self.names[number] ?? "UNKNOWN")).")
        }
    }

    @Test func aFailedFolderSizeNamesItsError() {
        for number in Self.numbers {
            let error = NativeFolderSize.error(number, "folder size", "/x")
            let description = String(cString: strerror(number))
            #expect(error.message == "\(Self.names[number] ?? "UNKNOWN"): \(description), folder size '/x'")
        }
    }
}
