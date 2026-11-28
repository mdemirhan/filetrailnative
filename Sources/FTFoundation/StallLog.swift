// The main thread's blocks of 8 ms or more, and the moments a measured run looks for, written for scripts/stalls.sh
import Darwin
import Foundation

/// Written as JSON lines to the file `FILETRAIL_STALLS_LOG` names, in debug builds only: each turn of the main run loop
/// that holds the thread 8 ms or more (`{"ev": "stall", "t": …, "ms": …}`), and the moments marked (`mark`): a step of a
/// scenario begun, a folder drawn, the previews all in. Times are in milliseconds since the process started, so a launch
/// counts from before the app's own code runs. Without the variable nothing is watched or written; a release build has
/// none of it.
public enum StallLog {
    /// A block of the main thread that is written: one frame at 120 Hz is 8.3 ms.
    public static let shortestMs = 8.0

    #if DEBUG
        private static let lock = NSLock()
        nonisolated(unsafe) private static var file: FileHandle?
        nonisolated(unsafe) private static var startedAt = 0.0
        nonisolated(unsafe) private static var on = false

        /// Whether this run is measured: it then leaves the keyboard with the app in front (`AppDelegate`).
        public static var isOn: Bool { on }

        /// Starts watching the main run loop when `FILETRAIL_STALLS_LOG` names a file. Called once, on the main thread,
        /// as the app starts.
        public static func start(environment: [String: String] = ProcessInfo.processInfo.environment) {
            guard !on, let path = environment["FILETRAIL_STALLS_LOG"], !path.isEmpty else { return }
            guard FileManager.default.createFile(atPath: path, contents: nil),
                let handle = FileHandle(forWritingAtPath: path)
            else { return }
            file = handle
            startedAt = processStart()
            on = true
            mark("start")
            watchMainRunLoop()
        }

        /// Writes `event` with its fields, at the time it happens.
        public static func mark(_ event: String, _ fields: [String: any Sendable] = [:]) {
            guard on else { return }
            var record: [String: Any] = ["ev": event, "t": rounded(now())]
            for (key, value) in fields { record[key] = value }
            write(record)
        }

        /// Milliseconds since the process started.
        static func now() -> Double { wallClock() - startedAt }

        private static func wallClock() -> Double {
            var time = timeval()
            gettimeofday(&time, nil)
            return Double(time.tv_sec) * 1000 + Double(time.tv_usec) / 1000
        }

        /// When the kernel started the process, on the same clock as `wallClock`; now if it can't say.
        private static func processStart() -> Double {
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
            guard sysctl(&name, 4, &info, &size, nil, 0) == 0 else { return wallClock() }
            let started = info.kp_proc.p_un.__p_starttime
            return Double(started.tv_sec) * 1000 + Double(started.tv_usec) / 1000
        }

        private static func rounded(_ ms: Double) -> Double { (ms * 10).rounded() / 10 }

        private static func write(_ record: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
            lock.lock()
            defer { lock.unlock() }
            file?.write(data + Data([0x0A]))
        }

        /// A turn of the main run loop runs from its waking to its next wait; one of `shortestMs` or more is written.
        private static func watchMainRunLoop() {
            nonisolated(unsafe) var awake = now()
            let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
            let observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, Int.max) { _, activity in
                let time = now()
                if activity == .beforeWaiting, time - awake >= shortestMs {
                    write(["ev": "stall", "t": rounded(awake), "ms": rounded(time - awake)])
                }
                awake = time
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        }
    #else
        public static var isOn: Bool { false }
        public static func start(environment: [String: String] = [:]) {}
        @inline(__always) public static func mark(_ event: String, _ fields: [String: any Sendable] = [:]) {}
    #endif
}
