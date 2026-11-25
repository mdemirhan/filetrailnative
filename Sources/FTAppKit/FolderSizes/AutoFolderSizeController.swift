import FTFoundation
import Foundation

/// Measures the folders the Info panel or the Info Row points at once they have stayed the same for a moment, one
/// after another, leaving those whose size is known, being measured or failed. Another folder being measured is
/// never stopped for them: the jobs run what was asked for first. Only one measurement of its own runs or waits at a
/// time, so the window keeps one automatic request.
/// When the folders change, a calculation started here, running or waiting, is stopped unless its folder is still
/// among them; one started by Calculate Size is left alone. What it measured inside is kept. One of its own stopped
/// part way (Stop) ends the rest until the folders change.
@MainActor
final class AutoFolderSizeController {
    private let sizes: WindowFolderSizes
    private let delay: Double
    private var paths: [String] = []
    private let scheduler: any TimerScheduling
    private var timer: TimerToken?
    /// The folders have stayed the same for the moment: they are measured.
    private var due = false
    /// One of its own was stopped part way: the rest wait for other folders.
    private var halted = false
    /// The folders it started a measurement of since the folders changed, so none is started twice.
    private var tried = Set<DiskPath>()
    /// While it starts one: what the start repaints doesn't move it on.
    private var starting = false
    private var startedPath: String?
    private var startedJob: String?

    init(
        sizes: WindowFolderSizes, delay: Double = AutoFolderSize.delayMilliseconds / 1000,
        scheduler: any TimerScheduling = TaskTimerScheduler()
    ) {
        self.sizes = sizes
        self.delay = delay
        self.scheduler = scheduler
        sizes.observe(self) { [weak self] in self?.advance() }
    }

    /// The folder to measure now (nil: none).
    func setPath(_ next: String?) { setPaths(next.map { [$0] } ?? []) }

    /// The folders to measure now, in order (empty: none). Called whenever they may have changed; only a change does
    /// anything.
    func setPaths(_ next: [String]) {
        // Another folder by its path's bytes: one whose name differs only in how an accent is spelled is another.
        let keys = next.map(DiskPath.init)
        guard keys != paths.map(DiskPath.init) else { return }
        timer?.cancel()
        timer = nil
        if let startedPath, !keys.contains(DiskPath(startedPath)) { leave() }
        paths = next
        due = false
        halted = false
        tried = startedPath.map { [DiskPath($0)] } ?? []
        guard !next.isEmpty else { return }
        timer = scheduler.schedule(after: delay) { [weak self] in
            guard let self else { return }
            self.timer = nil
            self.due = true
            self.advance()
        }
    }

    /// Stops its own measurement, unless asked for since (Calculate Size joins the measurement under way, under the
    /// same job): then it is no longer this one's to stop.
    private func leave() {
        if let startedPath, let startedJob, isOwn(startedPath, startedJob) {
            sizes.cancel(startedPath)
        }
        startedPath = nil
        startedJob = nil
    }

    private func isOwn(_ path: String, _ job: String) -> Bool {
        guard case .calculating(let running, _) = sizes.entry(path) else { return false }
        return running == job && !sizes.isAskedFor(path)
    }

    /// Once its own measurement is over, the next folder not known, not being measured and not failed.
    private func advance() {
        guard due, !halted, !starting else { return }
        if let path = startedPath, let job = startedJob {
            if isOwn(path, job) { return }
            startedPath = nil
            startedJob = nil
            // Stopped part way: the rest are left until the folders change.
            if case .idle = sizes.entry(path) {
                halted = true
                return
            }
        }
        for path in paths where !tried.contains(DiskPath(path)) {
            guard case .idle = sizes.entry(path) else { continue }
            tried.insert(DiskPath(path))
            starting = true
            sizes.calculate(path, recalculate: false, automatic: true)
            starting = false
            if case .calculating(let job, _) = sizes.entry(path), !job.isEmpty {
                startedPath = path
                startedJob = job
                return
            }
        }
    }

    func stop() { setPaths([]) }
}
