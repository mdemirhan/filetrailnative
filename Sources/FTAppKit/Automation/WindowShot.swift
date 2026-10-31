// The README's screenshots: what the screen shows of a window, as `screencapture -l` takes it
// (scripts/readme-screenshots.sh)
#if DEBUG
    import AppKit

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
            if let failure = captureScreen(of: window, to: screenFile) {
                return AutomationRunner.Outcome(.failed, failure)
            }
            return lay(screen: screenFile, over: file, of: window)
        }

        private static func captureScreen(of window: NSWindow, to file: URL) -> String? {
            let height = NSScreen.screens.first?.frame.height ?? 0
            let frame = window.frame
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = [
                "-x", "-R\(Int(frame.minX)),\(Int(height - frame.maxY)),\(Int(frame.width)),\(Int(frame.height))",
                file.path,
            ]
            do {
                try process.run()
            } catch {
                return "screencapture did not start: \(error.localizedDescription)"
            }
            process.waitUntilExit()
            return process.terminationStatus == 0 ? nil : "screencapture could not take the screen"
        }

        /// Off the main thread, during a marquee.
        nonisolated static func capture(id: Int, shadow: Bool, to file: URL) -> String? {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x"] + (shadow ? [] : ["-o"]) + ["-l\(id)", file.path]
            do {
                try process.run()
            } catch {
                return "screencapture did not start: \(error.localizedDescription)"
            }
            process.waitUntilExit()
            return process.terminationStatus == 0 && FileManager.default.fileExists(atPath: file.path)
                ? nil : "screencapture failed: allow File Trail in Privacy & Security › Screen Recording"
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
                x: (Double(shot.pixelsWide) - window.frame.width * 2) / 2, y: extra * (1 - topShareOfShadow),
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
