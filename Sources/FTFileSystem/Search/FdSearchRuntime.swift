import FTFoundation
import Foundation

/// What a running `fd` reports. Calls may come from any thread; `onClose` comes last, after all output.
public struct SearchProcessEvents: Sendable {
    public var onStdout: @Sendable (Data) -> Void
    public var onStderr: @Sendable (Data) -> Void
    /// The process could not be started (or failed).
    public var onError: @Sendable (String) -> Void
    /// The process ended: its exit code, or the signal that ended it.
    public var onClose: @Sendable (_ code: Int32?, _ signal: Int32?) -> Void

    public init(
        onStdout: @escaping @Sendable (Data) -> Void, onStderr: @escaping @Sendable (Data) -> Void,
        onError: @escaping @Sendable (String) -> Void,
        onClose: @escaping @Sendable (_ code: Int32?, _ signal: Int32?) -> Void
    ) {
        self.onStdout = onStdout
        self.onStderr = onStderr
        self.onError = onError
        self.onClose = onClose
    }
}

public protocol SearchProcess: AnyObject, Sendable {
    /// SIGTERM.
    func terminate()
}

/// Starts the program in `cwd` with no input, and reports through `events`.
public typealias SearchSpawn =
    @Sendable (
        _ file: String, _ args: [String], _ cwd: String, _ events: SearchProcessEvents
    ) -> SearchProcess

/// Searches run as `fd` processes, one per job, whose NUL-separated output is parsed as it arrives. The UI asks for
/// the results found since its last look (`getUpdate`).
public final class FdSearchRuntime: @unchecked Sendable {
    private static let maxFinishedJobRecords = 64

    /// What fd can't tell: it hides by the name alone, so what has the flag that hides an item, or is in a folder that
    /// has it, is told here. A folder's answer is kept for the search, so a folder of many results is looked at once,
    /// and they are dropped without each being looked at. The folder the search starts in, and what is above it, don't
    /// count: looking inside a hidden folder is what was asked. fd says where a result really is (/private/tmp for
    /// /tmp), which may not be how the folder was spelled.
    struct HiddenFilter {
        private let tops: [String]
        let hasHiddenFlag: @Sendable (String) -> Bool
        var folders: [String: Bool] = [:]

        init(rootPath: String, realRootPath: String?, hasHiddenFlag: @escaping @Sendable (String) -> Bool) {
            tops = [rootPath, realRootPath ?? rootPath].map { $0.hasSuffix("/") ? $0 : $0 + "/" }
            self.hasHiddenFlag = hasHiddenFlag
        }

        mutating func isInHiddenFolder(_ path: String) -> Bool {
            let parent = NodePath.dirname(path)
            guard parent != "/", tops.contains(where: { parent.hasPrefix($0) }) else { return false }
            if let known = folders[parent] { return known }
            let hidden = isInHiddenFolder(parent) || hasHiddenFlag(parent)
            folders[parent] = hidden
            return hidden
        }
    }

    private struct Job {
        var rootPath: String
        var includeHidden: Bool
        var filter: HiddenFilter
        /// For Plain Text, what decides which of fd's results count (fd's pattern finds at least those).
        var judge: Judge?
        var items: [SearchResultItem] = []
        var status: SearchJobStatus = .running
        var truncated = false
        var error: String?
        var process: SearchProcess?
        var stdoutBuffer = Data()
        var stderr = Data()
        var done = false

        /// `records` with what reading them needs. The filter is lent with the folders it knows, so the reader adds to
        /// them without copying them, and gives it back with the results.
        mutating func lend(_ records: Data) -> Reading {
            let reading = Reading(
                records: records, rootPath: rootPath, includeHidden: includeHidden, filter: filter, judge: judge,
                room: SearchLimits.resultLimit - items.count)
            filter.folders = [:]
            return reading
        }

        /// Adds results read outside the lock; the process to stop when that makes the `SearchLimits.resultLimit`th.
        mutating func add(_ found: [SearchResultItem], from reading: Reading) -> SearchProcess? {
            filter = reading.filter
            for item in found {
                items.append(item)
                guard items.count >= SearchLimits.resultLimit else { continue }
                truncated = true
                status = .truncated
                done = true
                stdoutBuffer = Data()
                return process
            }
            return nil
        }
    }

    /// A job's records, taken out of it with what turning them into results needs, so the disk is looked at outside the
    /// lock.
    private struct Reading {
        /// NUL-separated paths, as fd writes them.
        var records: Data
        var rootPath: String
        var includeHidden: Bool
        var filter: HiddenFilter
        var judge: Judge?
        /// How many more results the job takes before it reaches `SearchLimits.resultLimit`.
        var room: Int

        /// The results among the records, at most `room` of them. Without hidden files, what has the flag that hides an
        /// item, or is in a folder that has it, is left out; with them, what has the flag is marked hidden.
        mutating func results() -> [SearchResultItem] {
            var found: [SearchResultItem] = []
            for record in records.split(separator: 0) where found.count < room {
                var item = SearchResults.item(rootPath: rootPath, outputPath: String(decoding: record, as: UTF8.self))
                if includeHidden {
                    item.isHidden = item.isHidden || filter.hasHiddenFlag(item.path)
                } else if filter.isInHiddenFolder(item.path) || filter.hasHiddenFlag(item.path) {
                    continue
                }
                if let judge, !judge.matcher.matches(judge.fullPath ? item.path : item.name) { continue }
                found.append(item)
            }
            return found
        }
    }

    /// A Plain Text search's own matching of what fd found: the name, or for a search of full paths the whole path.
    struct Judge: Sendable {
        var matcher: NameMatcher
        var fullPath: Bool

        init?(_ request: SearchRequest) {
            guard request.patternMode == .text, let matcher = NameMatcher(request.query, mode: .contains) else {
                return nil
            }
            self.matcher = matcher
            fullPath = request.matchScope == .path
        }
    }

    /// A finished job's terminal state, kept after its last results were handed out, so late or duplicate polls stay
    /// idempotent instead of throwing.
    private struct FinishedJob {
        var status: SearchJobStatus
        var truncated: Bool
        var error: String?
        var itemCount: Int
    }

    private let fdBinaryPath: String
    private let spawn: SearchSpawn
    private let hasHiddenFlag: @Sendable (String) -> Bool
    private let realPath: @Sendable (String) throws -> String
    private let lock = NSLock()
    private var jobs: [String: Job] = [:]
    private var finishedJobs: [String: FinishedJob] = [:]
    private var finishedOrder: [String] = []
    private var sequence = 0

    public init(
        fdBinaryPath: String, spawn: @escaping SearchSpawn = FdProcess.spawn,
        hasHiddenFlag: @escaping @Sendable (String) -> Bool = {
            (try? NativeFileSystem().lstat($0))?.hasHiddenFlag == true
        },
        realPath: @escaping @Sendable (String) throws -> String = MountTable.realPath
    ) {
        self.fdBinaryPath = fdBinaryPath
        self.spawn = spawn
        self.hasHiddenFlag = hasHiddenFlag
        self.realPath = realPath
    }

    public func startSearch(_ request: SearchRequest) -> SearchStartResponse {
        let rootPath = NodePath.resolve(request.rootPath)
        var resolved = request
        resolved.rootPath = rootPath
        // Looked up before the lock is taken: a disk slow to answer mustn't hold up the window's questions.
        let filter = HiddenFilter(
            rootPath: rootPath, realRootPath: try? realPath(rootPath), hasHiddenFlag: hasHiddenFlag)
        let jobId = lock.withLock {
            sequence += 1
            let id = "search-\(sequence)"
            jobs[id] = Job(
                rootPath: rootPath, includeHidden: request.includeHidden, filter: filter, judge: Judge(request))
            return id
        }
        let events = SearchProcessEvents(
            onStdout: { [weak self] data in self?.handleStdout(jobId, data) },
            onStderr: { [weak self] data in self?.handleStderr(jobId, data) },
            onError: { [weak self] message in self?.finishJob(jobId, status: .error, error: message) },
            onClose: { [weak self] code, signal in self?.handleClose(jobId, code: code, signal: signal) })
        let process = spawn(fdBinaryPath, FdSearchArgs.build(resolved), rootPath, events)
        let stopAtOnce = lock.withLock {
            guard jobs[jobId] != nil else { return true }
            jobs[jobId]?.process = process
            // Stopped (or the runtime closed) while it was starting.
            return jobs[jobId]?.status == .cancelled || jobs[jobId]?.status == .truncated
        }
        if stopAtOnce {
            process.terminate()
        }
        return SearchStartResponse(jobId: jobId, status: .running)
    }

    public func getUpdate(jobId: String, cursor: Int) throws -> SearchUpdate {
        try lock.withLock {
            guard let job = jobs[jobId] else {
                guard let finished = finishedJobs[jobId] else { throw UnknownSearchJob(jobId: jobId) }
                return SearchUpdate(
                    jobId: jobId, status: finished.status, items: [],
                    nextCursor: max(0, min(cursor, finished.itemCount)), done: true, truncated: finished.truncated,
                    error: finished.error)
            }
            let safeCursor = max(0, min(cursor, job.items.count))
            let items = Array(job.items[safeCursor...])
            let update = SearchUpdate(
                jobId: jobId, status: job.status, items: items, nextCursor: safeCursor + items.count, done: job.done,
                truncated: job.truncated, error: job.error)
            if job.done {
                // The final response already carries every remaining item, so the job can be released, but its
                // terminal state is remembered so later polls stay idempotent.
                jobs[jobId] = nil
                rememberFinished(jobId, job)
            }
            return update
        }
    }

    /// Stops a job (SIGTERM). A job unknown or already finished is fine: it answers `ok` all the same.
    public func cancelSearch(jobId: String) {
        let process: SearchProcess? = lock.withLock {
            guard var job = jobs[jobId] else { return nil }
            var toStop: SearchProcess?
            if !job.done {
                job.status = .cancelled
                job.done = true
                toStop = job.process
            }
            // Keep the terminal state so a poll already in flight gets a done response.
            jobs[jobId] = nil
            rememberFinished(jobId, job)
            return toStop
        }
        process?.terminate()
    }

    /// Every search still running is stopped, and all jobs are forgotten: called when the app quits, so no `fd` goes on
    /// searching after it.
    public func close() {
        let processes: [SearchProcess] = lock.withLock {
            var running: [SearchProcess] = []
            for job in jobs.values where !job.done {
                if let process = job.process { running.append(process) }
            }
            jobs.removeAll()
            finishedJobs.removeAll()
            finishedOrder.removeAll()
            return running
        }
        for process in processes {
            process.terminate()
        }
    }

    // MARK: - Output

    private func rememberFinished(_ jobId: String, _ job: Job) {
        finishedJobs[jobId] = FinishedJob(
            status: job.status, truncated: job.truncated, error: job.error, itemCount: job.items.count)
        finishedOrder.removeAll { $0 == jobId }
        finishedOrder.append(jobId)
        while finishedJobs.count > Self.maxFinishedJobRecords, let oldest = finishedOrder.first {
            finishedOrder.removeFirst()
            finishedJobs[oldest] = nil
        }
    }

    /// The complete records in each chunk are taken out under the lock and only the unterminated tail is carried over.
    /// They are turned into results on the reader's thread, which looks at the disk, and added under the lock again,
    /// with the count checked as each is added, so the search stops at its limit exactly.
    private func handleStdout(_ jobId: String, _ chunk: Data) {
        let taken: Reading? = lock.withLock {
            guard let tail = jobs[jobId]?.stdoutBuffer, jobs[jobId]?.done == false else { return nil }
            let buffer = tail.isEmpty ? chunk : tail + chunk
            let end = buffer.lastIndex(of: 0).map { buffer.index(after: $0) } ?? buffer.startIndex
            // A copy of the tail, so the buffer does not pin the whole chunk.
            jobs[jobId]?.stdoutBuffer = end < buffer.endIndex ? Data(buffer[end...]) : Data()
            guard end > buffer.startIndex else { return nil }
            return jobs[jobId]?.lend(buffer[..<end])
        }
        guard var reading = taken else { return }
        let found = reading.results()
        let toStop: SearchProcess? = lock.withLock {
            guard jobs[jobId]?.done == false else { return nil }
            return jobs[jobId]?.add(found, from: reading) ?? nil
        }
        toStop?.terminate()
    }

    private func handleStderr(_ jobId: String, _ chunk: Data) {
        lock.withLock { jobs[jobId]?.stderr.append(chunk) }
    }

    private func handleClose(_ jobId: String, code: Int32?, signal: Int32?) {
        // What is left after the last NUL is a record all the same, read as the others are.
        var trailing: Reading? = lock.withLock {
            guard let tail = jobs[jobId]?.stdoutBuffer, !tail.isEmpty, jobs[jobId]?.done == false else { return nil }
            jobs[jobId]?.stdoutBuffer = Data()
            return jobs[jobId]?.lend(tail)
        }
        let found = trailing?.results() ?? []
        lock.withLock {
            // Taken out while it is changed, so its results aren't copied.
            guard var job = jobs.removeValue(forKey: jobId) else { return }
            defer { jobs[jobId] = job }
            if let trailing, !job.done {
                // Over the limit here only ends the job, there is nothing left to stop.
                _ = job.add(found, from: trailing)
            }
            if job.status == .cancelled || job.status == .truncated {
                job.done = true
                return
            }
            if let signal, signal != SIGTERM {
                job.status = .error
                job.error =
                    Self.describeFdError(job.stderr).nonEmpty ?? "fd exited via signal \(Self.signalName(signal))"
                job.done = true
                return
            }
            if code == 0 {
                job.status = .complete
                job.done = true
                return
            }
            job.status = .error
            job.error =
                Self.describeFdError(job.stderr).nonEmpty ?? "fd exited with code \(code.map(String.init) ?? "null")"
            job.done = true
        }
    }

    private func finishJob(_ jobId: String, status: SearchJobStatus, error: String?) {
        lock.withLock {
            guard jobs[jobId] != nil else { return }
            jobs[jobId]?.status = status
            jobs[jobId]?.error = error
            jobs[jobId]?.done = true
        }
    }

    // MARK: - Errors

    /// What fd wrote about a failed search, without its own prefix and without the closing advice about command-line
    /// flags, which means nothing in the app.
    static func describeFdError(_ stderr: Data) -> String {
        var text = String(decoding: stderr, as: UTF8.self)
        // /\n\s*Note: [\s\S]*$/u
        if let note = noteAdvice.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            let range = Range(note.range, in: text)
        {
            text.removeSubrange(range)
        }
        // /^\[fd error\]:\s*/u
        if let prefix = text.range(of: "[fd error]:"), prefix.lowerBound == text.startIndex {
            text.removeSubrange(prefix)
            while let first = text.unicodeScalars.first, SearchResults.isJSWhitespace(first) {
                text.unicodeScalars.removeFirst()
            }
        }
        return SearchResults.jsTrimmed(text)
    }

    // swiftlint:disable:next force_try
    private static let noteAdvice = try! NSRegularExpression(
        pattern: #"\n[ \t\n\r\x{0B}\x{0C}\x{A0}\x{2028}\x{2029}\x{FEFF}]*Note: [\s\S]*$"#)

    static func signalName(_ signal: Int32) -> String {
        let names: [Int32: String] = [
            SIGHUP: "SIGHUP", SIGINT: "SIGINT", SIGQUIT: "SIGQUIT", SIGILL: "SIGILL", SIGTRAP: "SIGTRAP",
            SIGABRT: "SIGABRT", SIGBUS: "SIGBUS", SIGFPE: "SIGFPE", SIGKILL: "SIGKILL", SIGSEGV: "SIGSEGV",
            SIGSYS: "SIGSYS", SIGPIPE: "SIGPIPE", SIGALRM: "SIGALRM", SIGTERM: "SIGTERM", SIGUSR1: "SIGUSR1",
            SIGUSR2: "SIGUSR2",
        ]
        return names[signal] ?? "SIG\(signal)"
    }
}

extension String {
    fileprivate var nonEmpty: String? { isEmpty ? nil : self }
}
