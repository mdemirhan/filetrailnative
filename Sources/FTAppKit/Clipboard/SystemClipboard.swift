import AppKit
import FTFoundation

/// The system's clipboard as Paste as File reads it: what it would write, worked out again only once the clipboard
/// has changed, and the bytes it writes. File Copy, Cut and Paste never read it; they use the app's own clipboard.
/// The menus ask what it would write each time they open, so that is told from the clipboard's types where they say,
/// with nothing read; the bytes are read off the main thread, when the file is made.
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

    /// What Paste as File would write now, for the menus. Only an image with text beside it has its text read, as
    /// the text decides which of the two it is; text alone is taken as text unread.
    var choice: PasteAsFileChoice {
        let changeCount = pasteboard.changeCount
        if let looked, looked.changeCount == changeCount { return looked.choice }
        let types = types
        let choice =
            PasteAsFile.choose(types: types)
            ?? PasteAsFile.choose(types: types) { [pasteboard] in pasteboard.string(forType: .string) }
        looked = (changeCount, choice)
        return choice
    }

    /// What it would write, for the menus; nil for nothing.
    var kind: PasteAsFileKind? { choice.kind }

    private var types: [String] { pasteboard.types?.map(\.rawValue) ?? [] }

    /// What is on the clipboard to write, read at once: it may change while the file is being written.
    struct Contents: Sendable {
        var choice: PasteAsFileChoice
        /// The image's bytes as copied, or the text as UTF-8; nil when there is nothing to write.
        var data: Data?
        /// A password manager marked it as private.
        var concealed: Bool
    }

    /// Reads the clipboard off the main thread, as an image or a long text can be large: what it holds is decided
    /// from what was read, so text that turns out empty is nothing.
    func read() async -> Contents {
        let name = pasteboard.name.rawValue
        return await Task.detached(priority: .userInitiated) {
            Self.readNow(NSPasteboard(name: NSPasteboard.Name(name)))
        }.value
    }

    nonisolated static func readNow(_ pasteboard: NSPasteboard) -> Contents {
        let types = pasteboard.types?.map(\.rawValue) ?? []
        var text: String?
        let choice = PasteAsFile.choose(types: types) {
            text = pasteboard.string(forType: .string)
            return text
        }
        let data: Data? =
            switch choice {
            case .image(let format): pasteboard.data(forType: NSPasteboard.PasteboardType(format.typeIdentifier))
            case .text: text.map { Data($0.utf8) }
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
