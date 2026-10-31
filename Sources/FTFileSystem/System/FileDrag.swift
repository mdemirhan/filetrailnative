// Port of nativeStartFileDrag and FileTrailDragSource (packages/native-fs/src/native_filedrag.m, behavior only: the
// real mouse event replaces the synthesized one) and of startFileDrag, findDraggedAway and bringWindowToFront
// (apps/desktop/src/main/bootstrap/fileDrag.ts)
import AppKit
import FTFoundation
import Foundation

/// What a drag of files ended as (`DRAG_ENDED_*`): the drop's operation, Delete first.
public enum FileDragEnd: String, Sendable, Equatable {
    case copy, move, link, delete, none
}

/// Where a drag of files ended (`DRAG_ENDED_OVER_*`): a window of the app takes a drop on it itself.
public enum FileDragEndedOver: String, Sendable, Equatable {
    case thisWindow = "this_window"
    case anotherWindow = "another_window"
    case elsewhere
}

/// The drag's side in AppKit (`FileTrailDragSource`): what it allows, whether the keys narrow it, and how it ended.
@MainActor
public final class FileDragSource: NSObject, NSDraggingSource {
    /// The window the drag started from.
    public let windowNumber: Int
    public var onEnded: (FileDragEnd, FileDragEndedOver) -> Void
    /// The number of the window at a point on screen, and whether a window number is one of the app's.
    var windowNumberAt: (NSPoint) -> Int = { NSWindow.windowNumber(at: $0, belowWindowWithWindowNumber: 0) }
    var isAppWindow: (Int) -> Bool = { NSApp.window(withWindowNumber: $0) != nil }
    var mouseLocation: () -> NSPoint = { NSEvent.mouseLocation }

    /// The drags going on: a source is kept for as long as its drag lasts.
    private static var running: [ObjectIdentifier: FileDragSource] = [:]

    public init(windowNumber: Int, onEnded: @escaping (FileDragEnd, FileDragEndedOver) -> Void) {
        self.windowNumber = windowNumber
        self.onEnded = onEnded
    }

    /// Within the app the window picks move or copy itself from the keys held; outside, the drop decides, as with
    /// Finder's own drags (⌘ is Generic, a move; ⌥⌘ an alias; the Dock's Trash trashes).
    public nonisolated func draggingSession(
        _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        FileDrag.sourceOperationMask(context)
    }

    /// Over File Trail the keys don't narrow the drag (⌘ would narrow it to Generic, which a drop would refuse): the
    /// window reads ⌥ and ⌘ itself. Asked again as the drag moves.
    public nonisolated func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
        MainActor.assumeIsolated { isAppWindow(windowNumberAt(mouseLocation())) }
    }

    public nonisolated func draggingSession(
        _ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation
    ) {
        MainActor.assumeIsolated { ended(at: screenPoint, operation: operation) }
    }

    /// `endedAtPoint:operation:`.
    func ended(at screenPoint: NSPoint, operation: NSDragOperation) {
        let number = windowNumberAt(screenPoint)
        let over: FileDragEndedOver =
            number == windowNumber ? .thisWindow : isAppWindow(number) ? .anotherWindow : .elsewhere
        Self.running.removeValue(forKey: ObjectIdentifier(self))
        onEnded(FileDrag.end(of: operation), over)
    }

    func keep() { Self.running[ObjectIdentifier(self)] = self }
}

/// A drag of files out of a view, and what follows it.
public enum FileDrag {
    /// `DRAG_LABEL_MAX_WIDTH`, `DRAG_LABEL_PADDING_X`, `DRAG_LABEL_PADDING_Y`, `DRAG_ICON_SIZE`, `DRAG_LABEL_GAP`,
    /// `DRAG_LABEL_FONT_SIZE`.
    public static let labelMaxWidth: CGFloat = 240
    public static let labelPaddingX: CGFloat = 6
    public static let labelPaddingY: CGFloat = 1
    public static let iconSize: CGFloat = 64
    public static let labelGap: CGFloat = 2
    public static let labelFontSize: CGFloat = 12

    /// `sourceOperationMaskForDraggingContext`.
    public static func sourceOperationMask(_ context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? [.copy, .move] : [.copy, .move, .generic, .link, .delete]
    }

    /// The operation a drag ended with: Delete, then Move (or Generic), then Copy, then Link.
    public static func end(of operation: NSDragOperation) -> FileDragEnd {
        if operation.contains(.delete) { return .delete }
        if !operation.intersection([.move, .generic]).isEmpty { return .move }
        if operation.contains(.copy) { return .copy }
        if operation.contains(.link) { return .link }
        return .none
    }

    /// Whether the images can be drawn: each names a place a path can have.
    static func imagesAreValid(_ images: [FileDragImage]) -> Bool {
        images.allSatisfy { $0.index >= 0 && $0.index < Int(UInt32.max) }
    }

    /// `nativeStartFileDrag`: starts a drag of `paths` from `view` (file URLs only, no promises), each item setting
    /// off from where it shows (`images`, rects in the view's coordinates), the rest going along unseen, gathered into
    /// a stack under the pointer, and animating back when it is cancelled. False when it could not start: no window,
    /// nothing to drag, the button already up, or an image no path can have.
    @MainActor
    @discardableResult
    public static func start(
        from view: NSView, event: NSEvent, paths: [String], directories: [Bool], images: [FileDragImage],
        thumbnails: [Int: NSImage] = [:], buttonDown: Bool = NSEvent.pressedMouseButtons & 1 != 0,
        onEnded: @escaping (FileDragEnd, FileDragEndedOver) -> Void
    ) -> Bool {
        guard imagesAreValid(images), let window = view.window, !paths.isEmpty, buttonDown else { return false }
        var placed: [Int: FileDragImage] = [:]
        for image in images where image.index < paths.count { placed[image.index] = image }
        var items: [NSDraggingItem] = []
        var unseenFrame = NSRect.zero
        var anyPlaced = false
        for (index, path) in paths.enumerated() {
            let url =
                index < directories.count
                ? URL(fileURLWithPath: path, isDirectory: directories[index]) : URL(fileURLWithPath: path)
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            if let image = placed[index] {
                let icon = thumbnails[index] ?? NSWorkspace.shared.icon(forFile: path)
                let label = labelImage(FileManager.default.displayName(atPath: path), fontSize: image.nameFontSize)
                let name = image.nameRect
                let labelX = image.nameCentered ? name.midX - label.size.width / 2 : name.minX - labelPaddingX
                let labelRect = NSRect(
                    x: labelX, y: name.midY - label.size.height / 2, width: label.size.width,
                    height: label.size.height)
                setPicture(
                    item, icon: icon, iconRect: fit(icon.size, in: image.iconRect), label: label, labelRect: labelRect)
                if !anyPlaced {
                    unseenFrame = item.draggingFrame
                    anyPlaced = true
                }
            }
            items.append(item)
        }
        if !anyPlaced {
            // Nothing measured: the first item at the pointer, the rest in a pile under it.
            let pointer = view.convert(event.locationInWindow, from: nil)
            setPictureAtPointer(items[0], path: paths[0], view: view, pointer: pointer)
            unseenFrame = items[0].draggingFrame
        }
        for (index, item) in items.enumerated() where placed[index] == nil && !(index == 0 && !anyPlaced) {
            item.draggingFrame = unseenFrame
        }
        let source = FileDragSource(windowNumber: window.windowNumber, onEnded: onEnded)
        let session = view.beginDraggingSession(with: items, event: event, source: source)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .stack
        source.keep()
        return true
    }

    /// `label_image`: the name as Finder draws it in a drag, white on the accent in a capsule, shortened in the
    /// middle when it is long.
    @MainActor
    public static func labelImage(_ name: String, fontSize: Double) -> NSImage {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize), .foregroundColor: NSColor.white, .paragraphStyle: paragraph,
        ]
        let text = (name as NSString).size(withAttributes: attributes)
        let textWidth = min(ceil(text.width), labelMaxWidth - 2 * labelPaddingX)
        let size = NSSize(width: textWidth + 2 * labelPaddingX, height: ceil(text.height) + 2 * labelPaddingY)
        let background = NSColor.selectedContentBackgroundColor
        return NSImage(size: size, flipped: false) { rect in
            background.setFill()
            let radius = rect.height / 2
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            (name as NSString).draw(
                in: rect.insetBy(dx: labelPaddingX, dy: labelPaddingY), withAttributes: attributes)
            return true
        }
    }

    /// `fit_rect`: a picture fitted inside `box`, its proportions kept.
    public static func fit(_ size: NSSize, in box: NSRect) -> NSRect {
        guard size.width > 0, size.height > 0 else { return box }
        let scale = min(box.width / size.width, box.height / size.height)
        let fitted = NSSize(width: size.width * scale, height: size.height * scale)
        return NSRect(
            x: box.midX - fitted.width / 2, y: box.midY - fitted.height / 2, width: fitted.width, height: fitted.height)
    }

    /// `set_item_picture`: the icon and the label in their places, framed together.
    @MainActor
    static func setPicture(_ item: NSDraggingItem, icon: NSImage, iconRect: NSRect, label: NSImage, labelRect: NSRect) {
        let frame = iconRect.union(labelRect)
        let iconInFrame = iconRect.offsetBy(dx: -frame.minX, dy: -frame.minY)
        let labelInFrame = labelRect.offsetBy(dx: -frame.minX, dy: -frame.minY)
        item.draggingFrame = frame
        item.imageComponentsProvider = {
            let iconComponent = NSDraggingImageComponent(key: .icon)
            iconComponent.contents = icon
            iconComponent.frame = iconInFrame
            let labelComponent = NSDraggingImageComponent(key: .label)
            labelComponent.contents = label
            labelComponent.frame = labelInFrame
            return [iconComponent, labelComponent]
        }
    }

    /// `set_item_picture_at_pointer`: an item with no place on screen, its icon over its name, the pointer on it.
    @MainActor
    static func setPictureAtPointer(_ item: NSDraggingItem, path: String, view: NSView, pointer: NSPoint) {
        let icon = NSWorkspace.shared.icon(forFile: path)
        let label = labelImage(FileManager.default.displayName(atPath: path), fontSize: labelFontSize)
        let below: CGFloat = view.isFlipped ? 1 : -1
        let iconRect = NSRect(
            x: pointer.x - iconSize / 2, y: pointer.y - iconSize / 2, width: iconSize, height: iconSize)
        let labelMidY = iconRect.midY + below * (iconSize / 2 + labelGap + label.size.height / 2)
        let labelRect = NSRect(
            x: pointer.x - label.size.width / 2, y: labelMidY - label.size.height / 2, width: label.size.width,
            height: label.size.height)
        setPicture(item, icon: icon, iconRect: iconRect, label: label, labelRect: labelRect)
    }

    // MARK: After the drag

    /// `lstat`'s error, 0 when the path is there.
    public static let lstatError: @Sendable (String) -> Int32 = { path in
        var info = Darwin.stat()
        return Darwin.lstat(path, &info) == 0 ? 0 : errno
    }

    /// `findDraggedAway`: the dragged items no longer where they were. A link counts as itself, and an item that
    /// can't be looked at for another reason (a disk gone to sleep) is not taken for gone. `cleared`: what was left,
    /// read again (and the Trash, when the Dock's Trash took them).
    public static func findDraggedAway(
        _ paths: [String], intoTrash: Bool = false, homePath: String = NSHomeDirectory(),
        lstatError: @Sendable (String) -> Int32 = FileDrag.lstatError
    ) -> (gone: [String], cleared: [String]) {
        let gone = paths.filter { lstatError($0) == ENOENT }
        guard !gone.isEmpty else { return ([], []) }
        return (gone, intoTrash ? gone + [(homePath as NSString).appendingPathComponent(".Trash")] : gone)
    }

    /// `bringWindowToFront`: brings the app and `window` forward for a question about a drop made while another app
    /// was in front; when macOS keeps the other app in front, the Dock icon bounces once. True when it came forward.
    @MainActor
    public static func bringToFront(
        _ window: (any FrontWindow)?, focusApp: () -> Void = { NSApp.activate() },
        bounceDockIcon: () -> Void = { NSApp.requestUserAttention(.informationalRequest) },
        waitMs: Double = DragTimings.bringToFrontCheckMs
    ) async -> Bool {
        guard let window else { return false }
        focusApp()
        window.comeForward()
        try? await Task.sleep(nanoseconds: UInt64(max(0, waitMs) * 1_000_000))
        guard !window.isGone else { return false }
        let focused = window.isFocused
        if !focused { bounceDockIcon() }
        return focused
    }
}

/// A window a drop's question brings forward.
@MainActor
public protocol FrontWindow: AnyObject {
    func comeForward()
    var isFocused: Bool { get }
    /// Closed meanwhile.
    var isGone: Bool { get }
}

extension NSWindow: FrontWindow {
    public func comeForward() { makeKeyAndOrderFront(nil) }
    public var isFocused: Bool { isKeyWindow }
    public var isGone: Bool { !isVisible }
}
