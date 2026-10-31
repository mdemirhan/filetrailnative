// Port of openWriteJournal, readEntries, isEntry and writeWhole (apps/desktop/src/main/bootstrap/writeJournal.ts)
import Darwin
import Foundation
import os

/// Keeps the writes in progress that leave items under hidden names (Replaces, folder copies, large file copies)
/// in a small file, so the next start can finish or undo one that a crash or force quit interrupted. Each change
/// is in the file before the write goes on.
public final class FileWriteJournal: WriteJournal, @unchecked Sendable {
    private struct State {
        /// By id, in the order first added, as a JavaScript Map keeps them.
        var order: [String] = []
        var entries: [String: WriteJournalEntry] = [:]
    }

    private let filePath: String
    private let writeFile: (String, String) throws -> Void
    // Held while the file is written, so one write happens at a time and an older list never lands over a newer
    // one. (`writeFile` is only called with it held.)
    private let state: OSAllocatedUnfairLock<State>

    private init(
        filePath: String, entries: [WriteJournalEntry], writeFile: @escaping (String, String) throws -> Void
    ) {
        self.filePath = filePath
        self.writeFile = writeFile
        var state = State()
        for entry in entries {
            if state.entries[entry.id] == nil {
                state.order.append(entry.id)
            }
            state.entries[entry.id] = entry
        }
        self.state = OSAllocatedUnfairLock(initialState: state)
    }

    /// `openWriteJournal(filePath)`: the journal kept in `filePath`, with what it already holds. A file that can't
    /// be read as one is put aside (`<file>.unreadable-<ms>`), so the next write doesn't erase what it may still
    /// say, and the journal starts empty.
    public static func open(_ filePath: String) -> FileWriteJournal {
        open(filePath, writeFile: writeWhole)
    }

    /// `open` writing the file with `writeFile(path, contents)`: a test's, that fails as a full disk does.
    static func open(_ filePath: String, writeFile: @escaping (String, String) throws -> Void) -> FileWriteJournal {
        FileWriteJournal(filePath: filePath, entries: readEntries(filePath), writeFile: writeFile)
    }

    /// What it holds, in the order the entries were first added.
    public func entries() -> [WriteJournalEntry] {
        state.withLock { state in state.order.compactMap { state.entries[$0] } }
    }

    public func add(_ entry: WriteJournalEntry) throws {
        try state.withLock { state in
            if state.entries[entry.id] == nil {
                state.order.append(entry.id)
            }
            state.entries[entry.id] = entry
            try save(state)
        }
    }

    public func remove(_ id: String) throws {
        try state.withLock { state in
            guard state.entries.removeValue(forKey: id) != nil else { return }
            state.order.removeAll { $0 == id }
            try save(state)
        }
    }

    private func save(_ state: State) throws {
        let snapshot = JournalJSON.array(state.order.compactMap { state.entries[$0]?.jsonObject })
        do {
            try writeFile(filePath, snapshot)
        } catch {
            throw Self.recoveryInfoError(error)
        }
    }

    /// The file is on the startup disk, wherever the items go: a failure to write it is said as that, never as
    /// the destination's ("There isn't enough free space on the destination disk.").
    static func recoveryInfoError(_ error: any Error) -> OperationError {
        OperationError(
            errorCode(error) == "ENOSPC"
                ? "File Trail couldn't save its recovery information because the startup disk is full. Free some space there and try again."
                : "File Trail couldn't save its recovery information.",
            cause: error)
    }

    static func readEntries(_ filePath: String) -> [WriteJournalEntry] {
        guard let data = FileManager.default.contents(atPath: filePath) else { return [] }
        if let text = String(data: data, encoding: .utf8),
            let parsed = try? JSONSerialization.jsonObject(
                with: Data(text.utf8), options: [.fragmentsAllowed]), let list = parsed as? [Any]
        {
            return list.compactMap { WriteJournalEntry(json: $0) }
        }
        let milliseconds = Int64((Date().timeIntervalSince1970 * 1000).rounded(.down))
        _ = Darwin.rename(filePath, "\(filePath).unreadable-\(milliseconds)")
        return []
    }

    /// Written next to the file, then renamed over it: a crash or force quit mid-write leaves the previous list,
    /// never half of one. It isn't flushed to the drive, which on macOS costs milliseconds each time and a paste
    /// writes many times, so a power cut may lose the latest changes.
    static func writeWhole(_ filePath: String, _ contents: String) throws {
        let temporaryPath = "\(filePath).tmp"
        let descriptor = Darwin.open(temporaryPath, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o666)
        guard descriptor >= 0 else {
            throw NativeError.errno(errno, syscall: "open", path: temporaryPath)
        }
        let bytes = Array(contents.utf8)
        var written = 0
        while written < bytes.count {
            let count = bytes[written...].withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
            if count < 0 {
                let errnum = errno
                if errnum == EINTR { continue }
                close(descriptor)
                throw NativeError.errno(errnum, syscall: "write", path: temporaryPath)
            }
            written += count
        }
        if close(descriptor) != 0 {
            throw NativeError.errno(errno, syscall: "close", path: temporaryPath)
        }
        if Darwin.rename(temporaryPath, filePath) != 0 {
            throw NativeError.errno(errno, syscall: "rename", path: temporaryPath, dest: filePath)
        }
    }
}

/// `JSON.stringify` of the journal's plain values, keys in the order given.
enum JournalJSON {
    static func array(_ objects: [[(String, Any)]]) -> String {
        "[" + objects.map(object).joined(separator: ",") + "]"
    }

    static func object(_ members: [(String, Any)]) -> String {
        "{" + members.map { string($0.0) + ":" + value($0.1) }.joined(separator: ",") + "}"
    }

    private static func value(_ value: Any) -> String {
        switch value {
        case let text as String: string(text)
        case let flag as Bool: flag ? "true" : "false"
        case let members as [(String, Any)]: object(members)
        case let list as [[(String, Any)]]: "[" + list.map(object).joined(separator: ",") + "]"
        default: "null"
        }
    }

    static func string(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    let hex = String(scalar.value, radix: 16)
                    out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}
