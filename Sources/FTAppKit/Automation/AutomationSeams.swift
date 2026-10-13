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

    @MainActor
    enum AutomationDrag {
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
