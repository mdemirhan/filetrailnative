// Port of FdSearchRuntime (packages/core/src/search/fdSearch.ts) and the search parts of packages/core/src/worker/explorerWorker.ts
import FTFoundation
import Foundation

/// What a running `fd` reports. Calls may come from any thread; `onClose` comes last, after all output.
public struct SearchProcessEvents: Sendable {
    public var onStdout: @Sendable (Data) -> Void
    public var onStderr: @Sendable (Data) -> Void
    /// The process could not be started (or failed): the Node `error` event.
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

/// `SpawnLike`: starts the program in `cwd` with no input, and reports through `events`.
public typealias SearchSpawn =
    @Sendable (
        _ file: String, _ args: [String], _ cwd: String, _ events: SearchProcessEvents
    ) -> SearchProcess

/// Searches run as `fd` processes, one per job, whose NUL-separated output is parsed as it arrives. The UI asks for
/// the results found since its last look (`getUpdate`), or takes them as a stream (`results`).
public final class FdSearchRuntime: @unchecked Sendable {
    public static let resultLimit = 20_000
    private static let maxFinishedJobRecords = 64

    private struct Job {
        var rootPath: String
        var items: [SearchResultItem] = []
        var status: SearchJobStatus = .running
        var truncated = false
        var error: String?
        var process: SearchProcess?
        var stdoutBuffer = Data()
        var stderr = Data()
        var done = false
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
    private let lock = NSLock()
    private var jobs: [String: Job] = [:]
    private var finishedJobs: [String: FinishedJob] = [:]
    private var finishedOrder: [String] = []
    private var sequence = 0

    public init(fdBinaryPath: String, spawn: @escaping SearchSpawn = FdProcess.spawn) {
        self.fdBinaryPath = fdBinaryPath
        self.spawn = spawn
    }

    public func startSearch(_ request: SearchRequest) -> SearchStartResponse {
        let rootPath = NodePath.resolve(request.rootPath)
        var resolved = request
        resolved.rootPath = rootPath
        let jobId = lock.withLock {
            sequence += 1
            let id = "search-\(sequence)"
            jobs[id] = Job(rootPath: rootPath)
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

    /// Starts a search and streams its results in batches (polled as the UI does, every `interval`), ending with the
    /// batch that has `done`. Dropping the stream before then cancels the search.
    public func results(
        for request: SearchRequest, interval: Duration = .milliseconds(120)
    ) -> AsyncStream<SearchUpdate> {
        let jobId = startSearch(request).jobId
        return AsyncStream { continuation in
            let task = Task {
                var cursor = 0
                while !Task.isCancelled {
                    guard let update = try? self.getUpdate(jobId: jobId, cursor: cursor) else { break }
                    cursor = update.nextCursor
                    if !update.items.isEmpty || update.done {
                        continuation.yield(update)
                    }
                    if update.done { break }
                    try? await Task.sleep(for: interval)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
                self.cancelSearch(jobId: jobId)
            }
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

    private func handleStdout(_ jobId: String, _ chunk: Data) {
        let toStop: SearchProcess? = lock.withLock {
            guard var job = jobs[jobId], !job.done else { return nil }
            // Complete records are parsed out of each chunk at once; only the unterminated tail is carried over.
            let buffer = job.stdoutBuffer.isEmpty ? chunk : job.stdoutBuffer + chunk
            var start = buffer.startIndex
            var stop: SearchProcess?
            while let separator = buffer[start...].firstIndex(of: 0) {
                let entry = String(decoding: buffer[start..<separator], as: UTF8.self)
                start = buffer.index(after: separator)
                if !entry.isEmpty {
                    stop = append(entry, to: &job)
                    if job.truncated {
                        job.stdoutBuffer = Data()
                        jobs[jobId] = job
                        return stop
                    }
                }
            }
            // A copy of the tail, so the buffer does not pin the whole chunk.
            job.stdoutBuffer = start < buffer.endIndex ? Data(buffer[start...]) : Data()
            jobs[jobId] = job
            return stop
        }
        toStop?.terminate()
    }

    private func handleStderr(_ jobId: String, _ chunk: Data) {
        lock.withLock { jobs[jobId]?.stderr.append(chunk) }
    }

    /// Adds a result; the process to stop when that makes the 20,000th.
    private func append(_ output: String, to job: inout Job) -> SearchProcess? {
        job.items.append(SearchResults.item(rootPath: job.rootPath, outputPath: output))
        guard job.items.count >= Self.resultLimit else { return nil }
        job.truncated = true
        job.status = .truncated
        job.done = true
        return job.process
    }

    private func handleClose(_ jobId: String, code: Int32?, signal: Int32?) {
        lock.withLock {
            guard var job = jobs[jobId] else { return }
            defer { jobs[jobId] = job }
            if !job.stdoutBuffer.isEmpty && !job.done {
                var trailing = String(decoding: job.stdoutBuffer, as: UTF8.self)
                while trailing.hasSuffix("\0") { trailing.removeLast() }
                if !trailing.isEmpty {
                    // Over the limit here only ends the job, there is nothing left to stop.
                    _ = append(trailing, to: &job)
                }
                job.stdoutBuffer = Data()
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
