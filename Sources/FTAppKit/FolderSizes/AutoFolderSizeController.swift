import FTFoundation
import Foundation

/// Measures the folder the Info panel or the Info Row points at once it has stayed the same for a moment, unless its size is known, being
/// measured or failed. While another folder of the window is being measured it waits for that to end, as a new
/// calculation would stop it, and then measures the folder pointed at by then. When the folder changes or goes, a
/// calculation started here and still running is stopped; one started by Calculate Size is left alone. What it
/// measured inside is kept.
@MainActor
final class AutoFolderSizeController {
    private let sizes: WindowFolderSizes
    private let delay: Double
    private var path: String?
    private let scheduler: any TimerScheduling
    private var timer: TimerToken?
    private var startedPath: String?
    private var startedJob: String?
    /// The folder that stayed long enough while another was being measured: measured once that ends.
    private var waiting: String?

    init(
        sizes: WindowFolderSizes, delay: Double = AutoFolderSize.delayMilliseconds / 1000,
        scheduler: any TimerScheduling = TaskTimerScheduler()
    ) {
        self.sizes = sizes
        self.delay = delay
        self.scheduler = scheduler
        sizes.observe(self) { [weak self] in self?.sizesChanged() }
    }

    /// The folder to measure now (nil: none). Called whenever it may have changed; only a change does anything.
    func setPath(_ next: String?) {
        guard next != path else { return }
        leave()
        path = next
        guard let next else { return }
        timer = scheduler.schedule(after: delay) { [weak self] in self?.fire(next) }
    }

    private func leave() {
        timer?.cancel()
        timer = nil
        waiting = nil
        if let startedPath, let startedJob, case .calculating(let job) = sizes.entry(startedPath), job == startedJob {
            sizes.cancel(startedPath)
        }
        startedPath = nil
        startedJob = nil
    }

    private func fire(_ target: String) {
        timer = nil
        guard path == target else { return }
        guard case .idle = sizes.entry(target) else { return }
        if sizes.isCalculating {
            waiting = target
            return
        }
        waiting = nil
        sizes.calculate(target, recalculate: false, automatic: true)
        if case .calculating(let job) = sizes.entry(target), !job.isEmpty {
            startedPath = target
            startedJob = job
        }
    }

    /// The sizes changed: a folder waiting on another's calculation is measured once no calculation is under way.
    private func sizesChanged() {
        guard let waiting, !sizes.isCalculating else { return }
        fire(waiting)
    }

    func stop() { setPath(nil) }
}
