import AppKit
import FTFoundation

/// The system's clipboard as Paste as File reads it: what it would write, worked out again only once the clipboard
/// has changed, and the bytes it writes. File Copy, Cut and Paste never read it; they use the app's own clipboard.
@MainActor
final class SystemClipboard {
    /// The system's clipboard; tests give a private one, so they leave this Mac's alone.
    var pasteboard: NSPasteboard {
        didSet { looked = nil }
    }
    /// What the clipboard held when it was last looked at, by its change count.
    private var looked: (changeCount: Int, choice: PasteAsFileChoice)?

    init(_ pasteboard: NSPasteboard = SystemClipboard.appPasteboard) {
        self.pasteboard = pasteboard
    }

    /// The system's clipboard; in a debug build driven by a scenario, the one `FILETRAIL_SYSTEM_CLIPBOARD` names
    /// instead, so trying Paste as File leaves this Mac's clipboard as it was.
    nonisolated static var appPasteboard: NSPasteboard {
        #if DEBUG
            if let name = ProcessInfo.processInfo.environment["FILETRAIL_SYSTEM_CLIPBOARD"], !name.isEmpty {
                return NSPasteboard(name: NSPasteboard.Name(name))
            }
        #endif
        return .general
    }

    /// What Paste as File would write now.
    var choice: PasteAsFileChoice {
        let changeCount = pasteboard.changeCount
        if let looked, looked.changeCount == changeCount { return looked.choice }
        let choice = PasteAsFile.choose(types: types) { [pasteboard] in pasteboard.string(forType: .string) }
        looked = (changeCount, choice)
        return choice
    }

    /// What it would write, for the menus; nil for nothing.
    var kind: PasteAsFileKind? { choice.kind }

    private var types: [String] { pasteboard.types?.map(\.rawValue) ?? [] }

    /// What is on the clipboard to write, read at once: it may change while the file is being written.
    struct Contents {
        var choice: PasteAsFileChoice
        /// The image's bytes as copied, or the text as UTF-8; nil when there is nothing to write.
        var data: Data?
        /// A password manager marked it as private.
        var concealed: Bool
    }

    func read() -> Contents {
        let choice = self.choice
        let data: Data? =
            switch choice {
            case .image(let format): pasteboard.data(forType: NSPasteboard.PasteboardType(format.typeIdentifier))
            case .text: pasteboard.string(forType: .string).map { Data($0.utf8) }
            case .files, .nothing: nil
            }
        return Contents(choice: choice, data: data, concealed: PasteAsFile.isConcealed(types: types))
    }

    /// A TIFF image as PNG, off the main thread; nil when it can't be read as an image.
    nonisolated static func png(fromTIFF data: Data) async -> Data? {
        await Task.detached(priority: .userInitiated) {
            NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
        }.value
    }
}
