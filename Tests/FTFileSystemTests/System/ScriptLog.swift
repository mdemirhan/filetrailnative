// The AppleScript sources a test's runner was handed
import Foundation

final class ScriptLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var sources: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
    func add(_ source: String) {
        lock.lock()
        recorded.append(source)
        lock.unlock()
    }
}
