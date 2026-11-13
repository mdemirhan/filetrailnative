// How long the main thread takes over each frame while the folder's view scrolls: the scenario's `scroll` step and the
// release's frame-time tests measure the same way
#if DEBUG
    import AppKit

    /// The frame times of one scroll of the folder's view, in milliseconds.
    struct ScrollFrameTimes: Equatable, Sendable {
        /// A frame at 120 Hz.
        static let frameMs = 1000.0 / 120

        var times: [Double]

        var count: Int { times.count }
        var medianMs: Double { times.isEmpty ? 0 : times.sorted()[times.count / 2] }
        var slowestMs: Double { times.max() ?? 0 }
        /// The frames that took longer than a frame.
        var lateCount: Int { times.filter { $0 > Self.frameMs }.count }
        /// The share of frames that took longer than a frame, 0 to 1.
        var lateShare: Double { times.isEmpty ? 0 : Double(lateCount) / Double(times.count) }

        /// The scroll view of the folder on screen in `window`: the Icons view's or the Compact List's, else the List's.
        @MainActor
        static func folderScrollView(in window: NSWindow) -> NSScrollView? {
            Views.first(NSCollectionView.self, in: window.contentView)?.enclosingScrollView
                ?? Views.folderTable(in: window)?.enclosingScrollView
        }

        /// Scrolls the folder's view by `distance` points over `milliseconds`, a step each frame at 120 Hz (sideways in
        /// the Compact List), timing the main thread over each frame: the scroll, the layout of the items it brings in,
        /// their drawing and the commit. It moves the clip view itself, so it times the main thread's part of scrolling,
        /// which a trackpad's responsive scrolling would otherwise hide. Nil with no folder view.
        @MainActor
        static func measure(by distance: Double, milliseconds: Int, window: NSWindow) async -> ScrollFrameTimes? {
            guard let scrollView = folderScrollView(in: window) else { return nil }
            let clip = scrollView.contentView
            let start = clip.bounds.origin
            let document = scrollView.documentView?.frame.size ?? .zero
            let maxX = max(0, document.width - clip.bounds.width)
            let maxY = max(0, document.height - clip.bounds.height)
            let sideways = (scrollView as? ItemGridScrollView)?.wheelScrollsSideways == true
            let count = max(1, Int(Double(milliseconds) / frameMs))
            var times: [Double] = []
            for step in 1...count {
                let began = ContinuousClock.now
                let along = distance * Double(step) / Double(count)
                clip.scroll(
                    to: sideways
                        ? NSPoint(x: min(maxX, max(0, start.x + along)), y: start.y)
                        : NSPoint(x: start.x, y: min(maxY, max(0, start.y + along))))
                scrollView.reflectScrolledClipView(clip)
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                CATransaction.flush()
                times.append(Double((ContinuousClock.now - began).milliseconds))
                try? await Task.sleep(for: .milliseconds(Int(frameMs)))
            }
            return ScrollFrameTimes(times: times)
        }
    }
#endif
