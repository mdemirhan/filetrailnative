import Foundation
import Testing
@testable import FTOperations

struct ReviewFolderMetadataTests {
    // applyDirectoryMetadata adds the source to metadataNotCopied before the chmod + utimes fallback, whose
    // error its callers swallow; the move must still keep its original.
    // F-405
    @Test func aMoveWhoseFallbackThrowsStillSaysTheMetadataWasNotCopied() {
        let refused = NativeError.errno(ENOTSUP, syscall: "copyfile", path: "/s", dest: "/d")
        var keepOriginal = false
        do {
            try FolderMetadata.apply(
                source: "/s", destination: "/d", sourceMode: 0o755, sourceMtimeMs: 1500, moving: true,
                onNotCopied: { keepOriginal = true },
                copyMetadata: { _, _ in throw refused },
                chmod: { _, _ in throw NativeError.errno(EPERM, syscall: "chmod", path: "/d") },
                utimes: { _, _, _ in })
        } catch {
            // swallowed as the original does
        }
        #expect(keepOriginal)
    }
}
