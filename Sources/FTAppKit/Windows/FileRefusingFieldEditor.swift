// Port of the text field rule of handleWindowDragOver and handleWindowDrop in apps/desktop/src/renderer/hooks/useExplorerDragAndDrop.ts
import AppKit

/// The field editor of an explorer window. A text field takes no files: a drop would type their paths in. It answers
/// for them rather than unregistering their type, or the drag would go on to whatever is behind the field. Other
/// drags (text) it leaves alone.
final class FileRefusingFieldEditor: NSTextView {
    static func carriesFiles(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        Self.carriesFiles(sender.draggingPasteboard) ? [] : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        Self.carriesFiles(sender.draggingPasteboard) ? [] : super.draggingUpdated(sender)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        Self.carriesFiles(sender.draggingPasteboard) ? false : super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        Self.carriesFiles(sender.draggingPasteboard) ? false : super.performDragOperation(sender)
    }
}
