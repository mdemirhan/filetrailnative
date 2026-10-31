// Port of getTrashState and emptyTrash (apps/desktop/src/main/bootstrap/systemHandlers.ts)
import Darwin
import Foundation

public enum TrashState {
    /// Lists a folder's names; throws a `POSIXError` as `readdir` does.
    public typealias Reader = @Sendable (String) throws -> [String]

    public static let readDirectory: Reader = { path in
        guard let directory = opendir(path) else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { closedir(directory) }
        var names: [String] = []
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }

    /// Whether the Trashes hold anything Finder's Empty Trash would erase: the home folder's, and each other disk's
    /// for this user. Finder's own .DS_Store doesn't count. `nil` when a Trash can't be read (without Full Disk
    /// Access, macOS refuses to list it): Empty Trash then stays available, as nothing says it has nothing to do.
    /// Returns `empty`.
    public static func isEmpty(home: String, uid: UInt32, read: Reader = readDirectory) -> Bool? {
        var trashes = [home + "/.Trash"]
        let volumes = (try? read("/Volumes")) ?? []
        for volume in volumes { trashes.append("/Volumes/\(volume)/.Trashes/\(uid)") }
        var unknown = false
        for (index, trash) in trashes.enumerated() {
            let names: [String]
            do {
                names = try read(trash)
            } catch {
                let code = (error as? POSIXError)?.code
                // Another disk without a Trash of this user's has nothing to empty.
                if index > 0 && (code == .ENOENT || code == .ENOTDIR) { continue }
                unknown = true
                continue
            }
            if names.contains(where: { $0 != ".DS_Store" }) { return false }
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

    /// system:emptyTrash. What is reported is the script engine's own error line, not the script that ran.
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
