// Port of useAutoFolderSize (apps/desktop/src/renderer/hooks/useAutoFolderSize.ts)
import FTFoundation
import Foundation

/// Measures the folder the Info panel points at once it has stayed the same for a moment, unless its size is known, being
/// measured or failed, or another folder is being measured. When the folder changes or goes, a calculation started here
/// and still running is stopped; one started by Calculate Size is left alone. What it measured inside is kept.
@MainActor
final class AutoFolderSizeController {
    private let sizes: WindowFolderSizes
    private let delay: Double
    private var path: String?
    private var timer: DispatchWorkItem?
    private var startedPath: String?
    private var startedJob: String?

    init(sizes: WindowFolderSizes, delay: Double = AutoFolderSize.delayMilliseconds / 1000) {
        self.sizes = sizes
        self.delay = delay
    }

    /// The folder to measure now (nil: none). Called whenever it may have changed; only a change does anything.
    func setPath(_ next: String?) {
        guard next != path else { return }
        leave()
        path = next
        guard let next else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.fire(next) }
        }
        timer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func leave() {
        timer?.cancel()
        timer = nil
        if let startedPath, let startedJob, case .calculating(let job) = sizes.entry(startedPath), job == startedJob {
            sizes.cancel(startedPath)
        }
        startedPath = nil
        startedJob = nil
    }

    private func fire(_ target: String) {
        timer = nil
        guard path == target, !sizes.isCalculating else { return }
        guard case .idle = sizes.entry(target) else { return }
        sizes.calculate(target, recalculate: false, automatic: true)
        if case .calculating(let job) = sizes.entry(target), !job.isEmpty {
            startedPath = target
            startedJob = job
        }
    }

    func stop() { setPath(nil) }
}
