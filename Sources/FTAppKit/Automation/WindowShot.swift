// The README's screenshots: what the screen shows of a window, as `screencapture -l` takes it
// (scripts/readme-screenshots.sh)
#if DEBUG
    import AppKit
    import FTFoundation

    @MainActor
    enum WindowShot {
        /// How much of the room a window's shadow takes in its image lies above the window.
        private static let topShareOfShadow = 76.0 / 224.0
        /// A little more than a window's corners, whatever the macOS.
        private static let cornerRadius = 28.0

        static func take(_ window: NSWindow, to file: URL) -> AutomationRunner.Outcome {
            guard window.backingScaleFactor == 2 else {
                return AutomationRunner.Outcome(.failed, "the README's screenshots need a Retina display")
            }
            if let failure = capture(id: window.windowNumber, shadow: true, to: file) {
                return AutomationRunner.Outcome(.failed, failure)
            }
            // A sheet or a popover is a window of its own, which `screencapture -l` leaves out of its parent's image: what
            // the screen shows over the window's frame goes on top.
            guard window.attachedSheet != nil || !(window.childWindows ?? []).isEmpty else {
                return AutomationRunner.Outcome(.ok)
            }
            let screenFile = file.deletingPathExtension().appendingPathExtension("screen.png")
            defer { try? FileManager.default.removeItem(at: screenFile) }
            // What the screen shows over the window's frame is taken whole, another app's window over it too. macOS asks
            // whether File Trail may take the screen in a window of its own over this one, while the screen is taken: the
            // picture waits for the answer and is taken again.
            for attempt in 1...2 {
                if let failure = waitUntilUncovered(window) ?? captureScreen(of: window, to: screenFile) {
                    return AutomationRunner.Outcome(.failed, failure)
                }
                guard let covered = coveringWindow(over: window) else { break }
                if attempt == 2 { return AutomationRunner.Outcome(.failed, covered) }
            }
            return lay(screen: screenFile, over: file, of: window)
        }

        /// Gives whoever is at the Mac two minutes to answer or close a window over this one.
        private static func waitUntilUncovered(_ window: NSWindow) -> String? {
            guard var covered = coveringWindow(over: window) else { return nil }
            FileHandle.standardError.write(Data("Waiting: \(covered)\n".utf8))
            let deadline = Date(timeIntervalSinceNow: 120)
            while Date() < deadline {
                Thread.sleep(forTimeInterval: 0.5)
                guard let still = coveringWindow(over: window) else {
                    // The window closing takes a moment on screen.
                    Thread.sleep(forTimeInterval: 0.5)
                    return nil
                }
                covered = still
            }
            return covered
        }

        private static func coveringWindow(over window: NSWindow) -> String? {
            let own = ProcessInfo.processInfo.processIdentifier
            let height = NSScreen.screens.first?.frame.height ?? 0
            let frame = window.frame
            let flipped = CGRect(x: frame.minX, y: height - frame.maxY, width: frame.width, height: frame.height)
            let above =
                CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow], CGWindowID(window.windowNumber))
                as? [[String: Any]] ?? []
            for info in above {
                let owner = info[kCGWindowOwnerName as String] as? String ?? "another app"
                // The Dock's window spans the screen, clear but for the Dock, which the scenes keep clear of.
                guard info[kCGWindowOwnerPID as String] as? pid_t != own, owner != "Dock",
                    (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                    let bounds = (info[kCGWindowBounds as String] as? NSDictionary).flatMap({
                        CGRect(dictionaryRepresentation: $0)
                    }),
                    bounds.intersects(flipped)
                else { continue }
                return "a window of \(owner) is over the window: answer or close it"
            }
            return nil
        }

        private static func captureScreen(of window: NSWindow, to file: URL) -> String? {
            let height = NSScreen.screens.first?.frame.height ?? 0
            let frame = window.frame
            let process = Process()
            process.executableURL = screencapture
            process.arguments = [
                "-x", "-R\(Int(frame.minX)),\(Int(height - frame.maxY)),\(Int(frame.width)),\(Int(frame.height))",
                path(of: file),
            ]
            do {
                try process.run()
            } catch {
                return "screencapture did not start: \(error.localizedDescription)"
            }
            process.waitUntilExit()
            return process.terminationStatus == 0 ? nil : "screencapture could not take the screen"
        }

        private nonisolated static var screencapture: URL {
            DiskPath("/usr/sbin/screencapture").url(isDirectory: false)
        }

        /// The path of a picture the run writes, for the tool that takes it: the URL's own bytes.
        private nonisolated static func path(of file: URL) -> String {
            DiskPath(urlSpelling: file)?.string ?? ""
        }

        /// Off the main thread, during a marquee.
        nonisolated static func capture(id: Int, shadow: Bool, to file: URL) -> String? {
            let process = Process()
            process.executableURL = screencapture
            process.arguments = ["-x"] + (shadow ? [] : ["-o"]) + ["-l\(id)", path(of: file)]
            do {
                try process.run()
            } catch {
                return "screencapture did not start: \(error.localizedDescription)"
            }
            process.waitUntilExit()
            return process.terminationStatus == 0 && FileManager.default.fileExists(atPath: path(of: file))
                ? nil : "screencapture failed: allow File Trail in Privacy & Security › Screen Recording"
        }

        /// Where the window starts across its shot. The shadow takes as much room across as it does up and down, half
        /// on each side; a popover reaching past one side of the window (Folder View Options, over the status bar's
        /// symbol at the right end) widens the shot on that side alone.
        private static func windowLeft(in shot: NSBitmapImageRep, of window: NSWindow, extra: Double) -> Double {
            let children = window.childWindows ?? []
            let pastLeft = children.contains { $0.frame.minX < window.frame.minX }
            let pastRight = children.contains { $0.frame.maxX > window.frame.maxX }
            let width = window.frame.width * 2
            switch (pastLeft, pastRight) {
            case (false, true): return extra / 2
            case (true, false): return Double(shot.pixelsWide) - extra / 2 - width
            default: return (Double(shot.pixelsWide) - width) / 2
            }
        }

        /// The window's shot keeps its shadow; inside its rounded corners goes what the screen shows.
        private static func lay(screen screenFile: URL, over file: URL, of window: NSWindow) -> AutomationRunner.Outcome
        {
            guard let shot = NSBitmapImageRep(data: (try? Data(contentsOf: file)) ?? Data()),
                let top = NSBitmapImageRep(data: (try? Data(contentsOf: screenFile)) ?? Data()),
                let base = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: shot.pixelsWide, pixelsHigh: shot.pixelsHigh, bitsPerSample: 8,
                    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                    bitsPerPixel: 0),
                let context = NSGraphicsContext(bitmapImageRep: base)
            else { return AutomationRunner.Outcome(.failed, "could not read the captures") }
            let extra = (Double(shot.pixelsHigh) - window.frame.height * 2)
            let rect = NSRect(
                x: windowLeft(in: shot, of: window, extra: extra), y: extra * (1 - topShareOfShadow),
                width: window.frame.width * 2, height: window.frame.height * 2)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            shot.draw(in: NSRect(x: 0, y: 0, width: shot.pixelsWide, height: shot.pixelsHigh))
            NSBezierPath(roundedRect: rect, xRadius: cornerRadius * 2, yRadius: cornerRadius * 2).addClip()
            top.draw(in: rect)
            NSGraphicsContext.restoreGraphicsState()
            guard let data = base.representation(using: .png, properties: [:]),
                (try? data.write(to: file, options: .atomic)) != nil
            else { return AutomationRunner.Outcome(.failed, "could not write the capture") }
            return AutomationRunner.Outcome(.ok)
        }
    }

    extension AutomationRunner {
        /// A shot goes in the README: an explorer window's tree must show the demo project, never the Mac's own
        /// folders.
        func rootedElsewhere(_ window: NSWindow) -> String? {
            guard window.toolbar != nil, let root = currentController?.sidebarController.treeRootPath else {
                return nil
            }
            return root == scenario?.root ? nil : "the folder tree is rooted at \(root), not the demo project"
        }

        /// The pointer's way over empty space, with the box and what it holds on screen.
        func marqueeShot(start: NSPoint, end: NSPoint, file: URL, window: NSWindow) async -> Outcome {
            func inWindow(_ point: NSPoint) -> NSPoint { NSPoint(x: point.x, y: window.frame.height - point.y) }
            let id = window.windowNumber
            let result = FailureBox()
            let done = await MouseEvents.drag(
                from: inWindow(start), to: inWindow(end), in: window
            ) {
                result.message = WindowShot.capture(id: id, shadow: true, to: file)
            }
            if !done { return Outcome(.failed, "could not make the mouse events") }
            return result.message.map { Outcome(.failed, $0) } ?? Outcome(.ok)
        }

        private final class FailureBox: @unchecked Sendable {
            var message: String?
        }
    }
#endif
