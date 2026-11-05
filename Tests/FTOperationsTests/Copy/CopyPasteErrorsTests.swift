import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

struct CopyPasteErrorsTests {
    @Test func givesAReasonWithoutThePathForAKnownErrorCode() {
        let error = OperationError("ENOSPC: no space left on device, write '/x/y'", code: "ENOSPC")
        #expect(describeCopyPasteError(error) == "There isn't enough free space on the destination disk.")
    }

    // The write service's rm says "Path is a directory: rm returned EISDIR (is a directory) /var/…".
    @Test func readsNodesOwnCodeForAFolderRemovedAsAFile() {
        let error = OperationError("Path is a directory: rm returned EISDIR /var/x", code: "ERR_FS_EISDIR")
        #expect(describeCopyPasteError(error) == "A folder is in the way where a file was expected.")
    }

    @Test func fallsBackToTheErrorsOwnMessage() {
        #expect(describeCopyPasteError(OperationError("Something else")) == "Something else")
        #expect(describeCopyPasteError(OperationError("plain")) == "plain")
    }

    @Test func readsTheCodeOfASystemError() {
        #expect(describeCopyPasteError(POSIXError(.ENOSPC)) == "There isn't enough free space on the destination disk.")
        #expect(errorCode(POSIXError(.ENOTSUP)) == "ENOTSUP")
    }

    @Test func tellsALockedItemByItsFlags() {
        #expect(CopyPasteErrors.lockFlags == 0x2 | 0x4 | 0x20000 | 0x40000)
        #expect(CopyPasteErrors.userLockFlags == 0x2 | 0x4)
        #expect(isLocked({ _ in 0x2 }, "/a"))
        #expect(isLocked({ _ in 0x40000 }, "/a"))
        #expect(!isLocked({ _ in 0x8000 }, "/a"))
        #expect(!isLocked({ _ in throw OperationError("gone") }, "/a"))
        #expect(!isLocked(nil, "/a"))

        let refusal = OperationError("EPERM: operation not permitted", code: "EPERM")
        let flags: (String) throws -> UInt32 = { $0 == "/d/locked.txt" ? 0x2 : 0 }
        #expect(
            findLockedRefusal(flags, refusal, ["/d/free.txt", "/d/locked.txt"])?.message
                == "“locked.txt” is locked. Unlock it in Finder's Get Info and try again.")
        #expect(findLockedRefusal(flags, refusal, ["/d/free.txt"]) == nil)
        #expect(findLockedRefusal(flags, OperationError("full", code: "ENOSPC"), ["/d/locked.txt"]) == nil)
        #expect(lockedMessage("plain") == "“plain” is locked. Unlock it in Finder's Get Info and try again.")
        #expect(lockedMessage("/d/") == "“/d/” is locked. Unlock it in Finder's Get Info and try again.")
    }
}

struct CopyPasteErrorsGoldenTests {
    struct Input: Codable, Sendable {
        var kind: String
        var errno: Int32?
        var syscall: String?
        var path: String?
        var dest: String?
        var message: String?
        var code: Code?
        var value: String?
    }

    /// An error's `code`: a string, or a number (which `describeCopyPasteError` doesn't read).
    enum Code: Codable, Sendable {
        case text(String)
        case number(Double)

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                self = .text(text)
            } else {
                self = .number(try container.decode(Double.self))
            }
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .text(let text): try container.encode(text)
            case .number(let number): try container.encode(number)
            }
        }
    }

    struct Output: Codable, Sendable {
        var code: String?
        var message: String?
        var described: String
    }

    @Test func matchesTheReferenceForEveryErrnoAndNodeShapedErrors() throws {
        let cases: [GoldenCase<Input, Output>] = try Golden.load(suite: "copy-paste-errors")
        #expect(cases.count > 200)
        Golden.expectMatches(cases) { input in
            switch input.kind {
            case "native":
                let error = NativeError.errno(
                    input.errno ?? 0, syscall: input.syscall ?? "", path: input.path ?? "", dest: input.dest)
                return Output(code: error.code, message: error.message, described: describeCopyPasteError(error))
            case "error":
                let code: String? =
                    if case .text(let text) = input.code { text } else { nil }
                let error = OperationError(input.message ?? "", code: code)
                return Output(described: describeCopyPasteError(error))
            default:
                // A thrown string: its text is its message.
                return Output(described: describeCopyPasteError(OperationError(input.value ?? "")))
            }
        }
    }
}
