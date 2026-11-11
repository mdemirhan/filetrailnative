import AppKit
import FTFoundation
import Foundation

/// What a drag of files ended as: the drop's operation, Delete first.
public enum FileDragEnd: String, Sendable, Equatable {
    case copy, move, link, delete, none
}

/// Where a drag of files ended: a window of the app takes a drop on it itself.
public enum FileDragEndedOver: String, Sendable, Equatable {
    case thisWindow = "this_window"
    case anotherWindow = "another_window"
    case elsewhere
}

/// The drag's side in AppKit: what it allows, whether the keys narrow it, and how it ended.
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

    /// The drag ended at `screenPoint`: whether over this window, another of the app's windows or elsewhere, and
    /// what was done with the items, are told to `onEnded`.
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
    /// The sizes of the drag image's icon and label.
    public static let labelMaxWidth: CGFloat = 240
    public static let labelPaddingX: CGFloat = 6
    public static let labelPaddingY: CGFloat = 1
    public static let iconSize: CGFloat = 64
    public static let labelGap: CGFloat = 2
    public static let labelFontSize: CGFloat = 12

    /// How far a drag's pictures keep from the pointer.
    static let pointerGap: CGFloat = 16
    /// How far each picture of a stack sits from the one before it, across and down.
    static let stackStep: CGFloat = 4

    /// Where each of a stack's pictures goes in the stack's image, and the image's size: each a step down and to the
    /// right of the one before, the first at the top left. In an image that isn't flipped.
    static func stackLayout(_ sizes: [NSSize]) -> (size: NSSize, frames: [NSRect]) {
        let steps = CGFloat(max(sizes.count - 1, 0)) * stackStep
        let width = (sizes.map(\.width).max() ?? 0) + steps
        let height = (sizes.map(\.height).max() ?? 0) + steps
        let frames = sizes.enumerated().map { index, size in
            let step = CGFloat(index) * stackStep
            return NSRect(x: step, y: height - size.height - step, width: size.width, height: size.height)
        }
        return (NSSize(width: width, height: height), frames)
    }

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

    /// Starts a drag of `paths` from `view`'s window (file URLs only, no promises). Up to
    /// `FileDragImages.maxImages` items are drawn as they show (`images`, rects in the view's coordinates), or the first
    /// item with no picture measured, and they go beside the pointer whatever their number; the rest go along unseen.
    /// False when it could not start: no window, nothing to drag, the button already up, or an image no path can have.
    @MainActor
    @discardableResult
    public static func start(
        from view: NSView, event: NSEvent, paths: [String], directories: [Bool], images: [FileDragImage],
        thumbnails: [Int: NSImage] = [:], buttonDown: Bool = NSEvent.pressedMouseButtons & 1 != 0,
        onEnded: @escaping (FileDragEnd, FileDragEndedOver) -> Void
    ) -> Bool {
        guard imagesAreValid(images), let window = view.window, let content = window.contentView,
            let frameView = content.superview, !paths.isEmpty, buttonDown
        else { return false }
        // With many items AppKit measures their frames on other threads, up through the view the drag starts from, and
        // a view of the app may only be asked on the main thread. This one has only the window's own frame above it.
        let anchor = NSView(frame: .zero)
        frameView.addSubview(anchor, positioned: .below, relativeTo: content)
        var pictures: [Picture] = []
        for image in images where image.index < paths.count && pictures.count < FileDragImages.maxImages {
            let path = paths[image.index]
            let icon = thumbnails[image.index] ?? NSWorkspace.shared.icon(forFile: path)
            let label = labelImage(FileManager.default.displayName(atPath: path), fontSize: image.nameFontSize)
            let name = view.convert(image.nameRect, to: anchor)
            let labelX = image.nameCentered ? name.midX - label.size.width / 2 : name.minX - labelPaddingX
            pictures.append(
                Picture(
                    icon: icon, iconRect: fit(icon.size, in: view.convert(image.iconRect, to: anchor)), label: label,
                    labelRect: NSRect(
                        x: labelX, y: name.midY - label.size.height / 2, width: label.size.width,
                        height: label.size.height)))
        }
        if pictures.isEmpty { pictures.append(pictureOfPath(paths[0])) }
        let stack = stackImage(pictures)
        let pointer = anchor.convert(event.locationInWindow, from: nil)
        let frame = NSRect(
            x: pointer.x, y: pointer.y - stack.size.height, width: stack.size.width, height: stack.size.height)
        // The stack is one picture, on the first item; the others go along unseen.
        var items: [NSDraggingItem] = []
        for (index, path) in paths.enumerated() {
            let url =
                index < directories.count
                ? URL(fileURLWithPath: path, isDirectory: directories[index]) : URL(fileURLWithPath: path)
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            item.draggingFrame = frame
            items.append(item)
        }
        items[0].setDraggingFrame(frame, contents: stack)
        let source = FileDragSource(windowNumber: window.windowNumber) { end, over in
            anchor.removeFromSuperview()
            onEnded(end, over)
        }
        let session = anchor.beginDraggingSession(with: items, event: event, source: source)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
        source.keep()
        return true
    }

    /// The name as Finder draws it in a drag, white on the accent in a capsule, shortened in the
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

    /// A picture fitted inside `box`, its proportions kept.
    public static func fit(_ size: NSSize, in box: NSRect) -> NSRect {
        guard size.width > 0, size.height > 0 else { return box }
        let scale = min(box.width / size.width, box.height / size.height)
        let fitted = NSSize(width: size.width * scale, height: size.height * scale)
        return NSRect(
            x: box.midX - fitted.width / 2, y: box.midY - fitted.height / 2, width: fitted.width, height: fitted.height)
    }

    /// An item's icon and name, where they go relative to each other.
    struct Picture: @unchecked Sendable {
        let icon: NSImage
        let iconRect: NSRect
        let label: NSImage
        let labelRect: NSRect

        var frame: NSRect { iconRect.union(labelRect) }
    }

    /// An item with no place on screen, its icon over its name.
    @MainActor
    static func pictureOfPath(_ path: String) -> Picture {
        let label = labelImage(FileManager.default.displayName(atPath: path), fontSize: labelFontSize)
        let iconRect = NSRect(x: 0, y: 0, width: iconSize, height: iconSize)
        return Picture(
            icon: NSWorkspace.shared.icon(forFile: path), iconRect: iconRect, label: label,
            labelRect: NSRect(
                x: iconRect.midX - label.size.width / 2, y: iconRect.minY - labelGap - label.size.height,
                width: label.size.width, height: label.size.height))
    }

    /// The pictures drawn as one stack, the first on top, with `pointerGap` left clear above and to the left of it:
    /// AppKit keeps the image's corner close to the pointer.
    @MainActor
    static func stackImage(_ pictures: [Picture]) -> NSImage {
        let layout = stackLayout(pictures.map(\.frame.size))
        let size = NSSize(width: layout.size.width + pointerGap, height: layout.size.height + pointerGap)
        return NSImage(size: size, flipped: false) { _ in
            for (picture, frame) in zip(pictures, layout.frames).reversed() {
                let dx = frame.minX + pointerGap - picture.frame.minX
                let dy = frame.minY - picture.frame.minY
                picture.icon.draw(in: picture.iconRect.offsetBy(dx: dx, dy: dy))
                picture.label.draw(in: picture.labelRect.offsetBy(dx: dx, dy: dy))
            }
            return true
        }
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

    /// Brings the app and `window` forward for a question about a drop made while another app
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
