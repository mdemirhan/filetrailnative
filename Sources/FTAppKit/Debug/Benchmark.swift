// Port of the spike's Benchmark (no TypeScript source); drives tools/bench/run.sh.
import AppKit
import QuartzCore

/// Measures how long the main thread goes without running its run loop.
@MainActor
private final class StallMonitor {
    private let interval = 0.004
    private var last = CACurrentMediaTime()
    private(set) var worst = 0.0
    private var timer: Timer?

    func start() {
        last = CACurrentMediaTime()
        timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func reset() {
        worst = 0
        last = CACurrentMediaTime()
    }

    private func tick() {
        let now = CACurrentMediaTime()
        worst = max(worst, (now - last - interval) * 1000)
        last = now
    }
}

/// Collects frame intervals from a display link while a scroll runs.
@MainActor
private final class ScrollDriver: NSObject {
    private let scrollView: NSScrollView
    private let duration: Double
    private var link: CADisplayLink?
    private var startTime = 0.0
    private var previous = 0.0
    private(set) var frames: [Double] = []
    private var continuation: CheckedContinuation<Void, Never>?

    init(scrollView: NSScrollView, duration: Double) {
        self.scrollView = scrollView
        self.duration = duration
    }

    func run(in window: NSWindow) async {
        let link = window.displayLink(target: self, selector: #selector(step(_:)))
        self.link = link
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            link.add(to: .main, forMode: .common)
        }
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        if startTime == 0 {
            startTime = now
        } else {
            frames.append((now - previous) * 1000)
        }
        previous = now
        let fraction = min(1, (now - startTime) / duration)
        let clip = scrollView.contentView
        let maxY = max(0, (scrollView.documentView?.frame.height ?? 0) - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: maxY * fraction))
        scrollView.reflectScrolledClipView(clip)
        if fraction >= 1 {
            link.invalidate()
            self.link = nil
            continuation?.resume()
            continuation = nil
        }
    }
}

@MainActor
enum Benchmark {
    /// Opens each sub-folder of `root` and goes back, three times over, prints the
    /// median timings plus one `BENCH` JSON line, and quits. The environment
    /// variable FILETRAIL_BENCH_ONLY limits the run to one sub-folder by name.
    static func run(in controller: MainWindowController, root: URL) async {
        let only = ProcessInfo.processInfo.environment["FILETRAIL_BENCH_ONLY"]
        let folders =
            ((try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                options: [.skipsHiddenFiles])) ?? [])
            .filter {
                let values = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                return values?.isDirectory == true && values?.isPackage != true
            }
            .filter { only == nil || $0.lastPathComponent == only }
            .sorted { $0.path < $1.path }
            .prefix(20)

        let stalls = StallMonitor()
        stalls.start()
        try? await Task.sleep(for: .milliseconds(500))
        var allOpens: [NavigationTiming] = []
        var allBacks: [NavigationTiming] = []
        var perFolder: [String: [String: Double]] = [:]
        for folder in folders {
            var opens: [NavigationTiming] = []
            var backs: [NavigationTiming] = []
            stalls.reset()
            for _ in 0..<3 {
                if let timing = await controller.navigate(to: folder) { opens.append(timing) }
                try? await Task.sleep(for: .milliseconds(50))
                if let timing = await controller.navigate(to: root, history: .back) {
                    backs.append(timing)
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            allOpens += opens
            allBacks += backs
            perFolder[folder.lastPathComponent] = [
                "items": median(opens.map { Double($0.itemCount) }),
                "open_ms": median(opens.map { ($0.load + $0.display).milliseconds }),
                "read_ms": median(opens.map(\.read.milliseconds)),
                "display_ms": median(opens.map(\.display.milliseconds)),
                "back_ms": median(backs.map { ($0.load + $0.display).milliseconds }),
                "stall_ms": stalls.worst,
            ]
        }
        stalls.stop()
        report("open", allOpens)
        report("back", allBacks)
        emit(["kind": "bench", "folders": perFolder])
        NSApp.terminate(nil)
    }

    /// Prints the time from process start to the first folder being drawn, then quits.
    static func launch(_ controller: MainWindowController) {
        controller.onFirstDraw = {
            let milliseconds = (Date().timeIntervalSince1970 - processStart()) * 1000
            emit(["kind": "launch", "launch_ms": milliseconds])
            NSApp.terminate(nil)
        }
    }

    /// Scrolls the List view from top to bottom and prints frame-time statistics.
    static func scroll(in controller: MainWindowController) async {
        try? await Task.sleep(for: .seconds(1))
        guard let window = controller.window,
            let table = firstView(ofType: NSTableView.self, in: window.contentView),
            let scrollView = table.enclosingScrollView
        else {
            emit(["kind": "scroll", "error": "no list view"])
            NSApp.terminate(nil)
            return
        }
        let stalls = StallMonitor()
        stalls.start()
        let driver = ScrollDriver(scrollView: scrollView, duration: 3)
        await driver.run(in: window)
        stalls.stop()
        let frames = driver.frames.sorted()
        let p99 = frames.isEmpty ? 0 : frames[min(frames.count - 1, Int(Double(frames.count) * 0.99))]
        emit([
            "kind": "scroll", "rows": Double(table.numberOfRows), "frames": Double(frames.count),
            "frame_max_ms": frames.last ?? 0, "frame_p99_ms": p99, "stall_ms": stalls.worst,
        ])
        NSApp.terminate(nil)
    }

    /// Draws the window (title bar and toolbar included) into a PNG, then quits.
    /// For checking the look where screen recording isn't allowed.
    static func snapshot(_ controller: MainWindowController, to file: URL) async {
        try? await Task.sleep(for: .seconds(1.5))
        guard let frameView = controller.window?.contentView?.superview,
            let bitmap = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds)
        else { return }
        frameView.cacheDisplay(in: frameView.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: file)
        NSApp.terminate(nil)
    }

    private static func firstView<T: NSView>(ofType type: T.Type, in view: NSView?) -> T? {
        guard let view else { return nil }
        if let match = view as? T { return match }
        for child in view.subviews {
            if let match = firstView(ofType: type, in: child) { return match }
        }
        return nil
    }

    /// Wall-clock time the process started, from the kernel.
    private static func processStart() -> Double {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else { return Date().timeIntervalSince1970 }
        let start = info.kp_proc.p_un.__p_starttime
        return Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
    }

    private static func emit(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        else { return }
        print("BENCH " + text)
        fflush(stdout)
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }

    private static func report(_ name: String, _ timings: [NavigationTiming]) {
        let read = median(timings.map(\.read.milliseconds))
        let load = median(timings.map(\.load.milliseconds))
        let display = median(timings.map(\.display.milliseconds))
        let total = median(timings.map { ($0.load + $0.display).milliseconds })
        let worst = timings.map { ($0.load + $0.display).milliseconds }.max() ?? 0
        let items = median(timings.map { Double($0.itemCount) })
        print(
            String(
                format:
                    "%@: %d runs, median %.0f items: load %.1f ms (disk %.1f ms) + display %.1f ms = %.1f ms (worst %.1f ms)",
                name, timings.count, items, load, read, display, total, worst))
    }
}
