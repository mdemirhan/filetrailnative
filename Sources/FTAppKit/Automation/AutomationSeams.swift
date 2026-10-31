// Port of the drag steps of tools/capture/electron/driver.ts; no TypeScript source.
#if DEBUG
    import AppKit

    /// Debug seams for the `drag` step. A drag of files starts a native `NSDraggingSession`, which the
    /// window server runs and synthesized mouse events can't drive. A view that starts one adopts
    /// `AutomationDragSource`, and a view that takes drops adopts `AutomationDropTarget`; the step then
    /// hands the items straight to the drop handler, and the report says so.
    @MainActor
    protocol AutomationDragSource: AnyObject {
        /// The items a drag starting at `point` (in the view's coordinates) would carry.
        func automationDragItems(at point: NSPoint) -> [URL]
    }

    @MainActor
    protocol AutomationDropTarget: AnyObject {
        /// Takes a drop of `items` at `point` (in the view's coordinates). `allowed` is what the drag
        /// offers, as the modifier keys held set it. Answers whether the drop was taken.
        func automationDrop(_ items: [URL], at point: NSPoint, allowed: NSDragOperation) -> Bool
    }

    /// A drag inside the app that isn't files: what its drag session would write, and what the source does at its end.
    struct AutomationPasteboardDrag {
        var item: NSPasteboardItem
        var ended: () -> Void
    }

    @MainActor
    protocol AutomationPasteboardDragSource: AnyObject {
        /// The drag starting at `point` (in the view's coordinates), started; nil when no such drag starts there.
        func automationPasteboardDrag(at point: NSPoint) -> AutomationPasteboardDrag?
    }

    /// The drag `AutomationDrag.playFiles` shows a destination: files on their own pasteboard, from no source in this
    /// process, as a drag from another app is.
    @MainActor
    final class AutomationDraggingInfo: NSObject, @preconcurrency NSDraggingInfo {
        private static var lastSequence = -1000

        let draggingDestinationWindow: NSWindow?
        let draggingLocation: NSPoint
        let draggingPasteboard = NSPasteboard.withUniqueName()
        let draggingSequenceNumber: Int
        var draggingSourceOperationMask: NSDragOperation { [.copy, .move, .link, .generic] }
        var draggedImageLocation: NSPoint { draggingLocation }
        var draggedImage: NSImage? { nil }
        let draggingSource: Any?
        var draggingFormation = NSDraggingFormation.default
        var animatesToDestination = false
        var numberOfValidItemsForDrop: Int
        var springLoadingHighlight: NSSpringLoadingHighlight { .none }

        init(urls: [URL], location: NSPoint, window: NSWindow?) {
            draggingDestinationWindow = window
            draggingLocation = location
            numberOfValidItemsForDrop = urls.count
            draggingSource = nil
            Self.lastSequence -= 1
            draggingSequenceNumber = Self.lastSequence
            super.init()
            draggingPasteboard.clearContents()
            draggingPasteboard.writeObjects(urls as [NSURL])
        }

        /// A drag from a view of this app, with what its session writes.
        init(item: NSPasteboardItem, source: Any, location: NSPoint, window: NSWindow?) {
            draggingDestinationWindow = window
            draggingLocation = location
            numberOfValidItemsForDrop = 1
            draggingSource = source
            Self.lastSequence -= 1
            draggingSequenceNumber = Self.lastSequence
            super.init()
            draggingPasteboard.clearContents()
            draggingPasteboard.writeObjects([item])
        }

        func slideDraggedImage(to screenPoint: NSPoint) {}
        func resetSpringLoading() {}
        func enumerateDraggingItems(
            options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
            classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
            using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
        ) {}
    }

    @MainActor
    enum AutomationDrag {
        enum FileDragResult: Equatable {
            /// No view under the point takes files, so AppKit asks nobody.
            case noDestination
            /// The view AppKit asks answered that it takes none of them.
            case refused(by: String)
            /// The view offers to take them; the step stopped short of the drop.
            case offered(by: String)
            case dropped(by: String, taken: Bool)
        }

        /// The view AppKit sends a drag over `view`'s center to: the deepest one there, itself or above it, registered
        /// for a type on the pasteboard. An edited text field's field editor is the deepest one there, and it is
        /// registered for files; a field not being edited is registered for nothing.
        static func dragDestination(over view: NSView, carrying pasteboard: NSPasteboard) -> NSView? {
            let types = Set(pasteboard.types ?? [])
            var point = NSPoint(x: view.bounds.midX, y: view.bounds.midY)
            if let superview = view.superview { point = view.convert(point, to: superview) }
            var current: NSView? = view.hitTest(point) ?? view
            while let candidate = current {
                if !types.isDisjoint(with: candidate.registeredDraggedTypes) { return candidate }
                current = candidate.superview
            }
            return nil
        }

        /// Plays a drag of `urls` from another app over the center of `view`, through the view AppKit would ask: over
        /// it and held there until it offers to take them (5 s), or for a moment if it is to refuse. A native drag
        /// session can't be driven, so the info is ours; the answers are the app's.
        static func playFiles(_ urls: [URL], over view: NSView, refused: Bool, hold: Bool) async -> FileDragResult {
            let info = AutomationDraggingInfo(
                urls: urls, location: MouseEvents.center(of: view), window: view.window)
            defer { info.draggingPasteboard.releaseGlobally() }
            guard let destination = dragDestination(over: view, carrying: info.draggingPasteboard) else {
                return .noDestination
            }
            let name = String(describing: type(of: destination))
            var operation = destination.draggingEntered(info)
            let deadline = ContinuousClock.now + (refused ? .milliseconds(300) : .seconds(5))
            while operation.isEmpty || refused, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
                operation = destination.draggingUpdated(info)
            }
            if operation.isEmpty {
                destination.draggingExited(info)
                return .refused(by: name)
            }
            if refused || hold {
                destination.draggingExited(info)
                return .offered(by: name)
            }
            let taken = destination.prepareForDragOperation(info) && destination.performDragOperation(info)
            if taken { destination.concludeDragOperation(info) }
            return .dropped(by: name, taken: taken)
        }

        enum PasteboardDragResult: Equatable {
            case noDestination, refused, dropped
        }

        /// Plays a drag from a view of this app over `view`, to `point` (window coordinates), through the view AppKit
        /// would ask and what the drag put on the pasteboard. The session itself can't be driven; the rest is the app's.
        static func play(_ drag: AutomationPasteboardDrag, over view: NSView, at point: NSPoint) -> PasteboardDragResult
        {
            let info = AutomationDraggingInfo(item: drag.item, source: view, location: point, window: view.window)
            defer {
                drag.ended()
                info.draggingPasteboard.releaseGlobally()
            }
            guard let destination = dragDestination(over: view, carrying: info.draggingPasteboard) else {
                return .noDestination
            }
            if destination.draggingEntered(info).isEmpty || destination.draggingUpdated(info).isEmpty {
                destination.draggingExited(info)
                return .refused
            }
            guard destination.prepareForDragOperation(info), destination.performDragOperation(info) else {
                return .refused
            }
            destination.concludeDragOperation(info)
            return .dropped
        }

        /// What a drag offers with these modifiers held, as AppKit narrows a drag's mask: ⌥ copies,
        /// ⌘ moves, ⌥⌘ links.
        static func allowed(_ modifiers: NSEvent.ModifierFlags) -> NSDragOperation {
            switch (modifiers.contains(.option), modifiers.contains(.command)) {
            case (true, true): .link
            case (true, false): .copy
            case (false, true): .move
            case (false, false): [.copy, .move, .link, .generic]
            }
        }

        /// The view itself or the nearest view above it that adopts `T`.
        static func nearest<T>(_ type: T.Type, from view: NSView) -> (NSView, T)? {
            var current: NSView? = view
            while let candidate = current {
                if let adopted = candidate as? T { return (candidate, adopted) }
                current = candidate.superview
            }
            return nil
        }

        /// Whether a press at `point` (window coordinates) in a list or grid is on none of its items (empty space),
        /// where a drag is the view's own (a marquee), as the original's driver finds no entry under the press.
        static func pressesNoItem(_ view: NSView, at point: NSPoint) -> Bool {
            var current: NSView? = view
            while let candidate = current {
                if let table = candidate as? NSTableView, !(table is NSOutlineView) {
                    return table.row(at: table.convert(point, from: nil)) < 0
                }
                if let grid = candidate as? NSCollectionView {
                    return grid.indexPathForItem(at: grid.convert(point, from: nil)) == nil
                }
                current = candidate.superview
            }
            return false
        }

        /// Whether a drag from this view would start a native drag session (the list, icon and tree
        /// views do), which synthesized events must not start: it would wait for a real mouse.
        static func startsDraggingSession(_ view: NSView) -> Bool {
            var current: NSView? = view
            while let candidate = current {
                if candidate is NSTableView || candidate is NSCollectionView { return true }
                current = candidate.superview
            }
            return false
        }
    }
#endif
