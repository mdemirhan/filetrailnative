import Darwin
import Foundation

public enum TrashState {
    /// The first name in a folder that `matches`, nil when none does; throws a `POSIXError` as `readdir` does. It stops
    /// at that name: a Trash with thousands of items is not read in full to tell it has one.
    public typealias Reader = @Sendable (_ folder: String, _ matches: (String) -> Bool) throws -> String?

    public static let readDirectory: Reader = { path, matches in
        guard let directory = opendir(path) else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { closedir(directory) }
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if name != "." && name != ".." && matches(name) { return name }
        }
        return nil
    }

    /// Whether the Trashes hold anything Finder's Empty Trash would erase: the home folder's, and this user's on each
    /// other local disk, as `TrashFolders` has them (a network share has no Trash, and reading one may stall). Finder's
    /// own .DS_Store doesn't count. `nil` when a Trash can't be read (without Full Disk Access, macOS refuses to list
    /// it): Empty Trash then stays available, as nothing says it has nothing to do. Returns `empty`.
    public static func isEmpty(
        home: String, uid: UInt32, listMounts: @escaping @Sendable () -> [Mount] = MountTable.list,
        read: Reader = readDirectory
    ) -> Bool? {
        let folders = TrashFolders(homePath: home, uid: uid, listMounts: listMounts)
        let trashes = [folders.home] + folders.onOtherDisks
        var unknown = false
        for (index, trash) in trashes.enumerated() {
            let found: String?
            do {
                found = try read(trash) { $0 != ".DS_Store" }
            } catch {
                let code = (error as? POSIXError)?.code
                // Another disk without a Trash of this user's has nothing to empty.
                if index > 0 && (code == .ENOENT || code == .ENOTDIR) { continue }
                unknown = true
                continue
            }
            if found != nil { return false }
        }
        return unknown ? nil : true
    }

    // MARK: Empty Trash

    /// Finder empties the Trash. AppleScript gives up waiting for an answer after two minutes, which a large Trash
    /// takes longer than: Finder would carry on while File Trail said it failed. A day is the limit instead.
    public static let emptyTrashScript = """
        with timeout of 86400 seconds
        tell application "Finder" to empty trash
        end timeout
        """

    /// Runs AppleScript source; throws `AppleScriptFailure` with the script engine's own error line.
    public typealias ScriptRunner = @Sendable (String) async throws -> Void

    public struct AppleScriptFailure: Error, LocalizedError, Equatable {
        public let message: String
        public var errorDescription: String? { message }
        public init(message: String) { self.message = message }
    }

    /// In-process `NSAppleScript`, so the Apple Events prompt names File Trail. Run off the main thread: Finder may
    /// take long.
    public static let runAppleScript: ScriptRunner = { source in
        try await Task.detached {
            guard let script = NSAppleScript(source: source) else {
                throw AppleScriptFailure(message: "execution error: the script could not be made.")
            }
            var failure: NSDictionary?
            script.executeAndReturnError(&failure)
            if let failure {
                let message = failure[NSAppleScript.errorMessage] as? String ?? "The script failed."
                let number = failure[NSAppleScript.errorNumber] as? Int
                throw AppleScriptFailure(
                    message: "execution error: \(message)" + (number.map { " (\($0))" } ?? ""))
            }
        }.value
    }

    /// Empties the Trash through Finder. What is reported is the script engine's own error line, not the script that
    /// ran.
    public static func empty(run: ScriptRunner = runAppleScript) async -> OperationResult {
        do {
            try await run(emptyTrashScript)
            return .success
        } catch {
            let message = ApplicationPaths.trimmed(errorMessage(error))
            return .failure(message)
        }
    }
}
