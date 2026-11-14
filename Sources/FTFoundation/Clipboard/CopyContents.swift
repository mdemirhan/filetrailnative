import Foundation
import UniformTypeIdentifiers

/// What Copy Contents puts on the system's clipboard: a file's image or its text.
public enum CopyContentsKind: String, Sendable, Equatable, CaseIterable {
    case image, text
}

/// What a file's name says it holds, before it is read.
public enum CopyContentsGuess: String, Sendable, Equatable, CaseIterable {
    /// An image, by its kind.
    case image
    /// Text, by its kind.
    case text
    /// A kind the system doesn't know, or no extension at all: what it holds is found out as it is read.
    case unknown
    /// A kind that is neither (a PDF, an archive, a film): the right-click menu leaves the command out, and the menu
    /// bar's says why when it is chosen.
    case other

    /// What it would be copied as, when the name says.
    public var kind: CopyContentsKind? {
        switch self {
        case .image: .image
        case .text: .text
        case .unknown, .other: nil
        }
    }

    /// Whether the menus offer it: everything but a kind that is neither.
    public var isOffered: Bool { self != .other }
}

/// The rules of Copy Contents: which files it copies, as what, and what is said.
public enum CopyContents {
    /// The most text copied: a paste of more holds up most text fields.
    public static let textLimit: Int64 = 10 * 1_000_000
    /// The largest image file copied.
    public static let imageLimit: Int64 = 100 * 1_000_000

    /// Extensions of text the system calls something else (`.ts` is a video to it, `.svg` an image) or doesn't know.
    /// An SVG is copied as its markup, which is what is pasted into code.
    static let textExtensions: Set<String> = [
        "ts", "tsx", "jsx", "mjs", "cjs", "svg", "md", "markdown", "rs", "go", "kt", "kts", "toml", "yaml", "yml",
        "ini", "cfg", "conf", "env", "log", "vue", "svelte", "gradle", "lock", "tf", "proto", "graphql", "sql", "csv",
        "tsv",
    ]

    /// The extension, lowercased and without its dot; "" for none, as for a name that starts with its only dot.
    static func extensionName(_ name: String) -> String {
        String(NodePath.extname(name).dropFirst()).lowercased()
    }

    /// What the file's name says it holds.
    public static func guess(forName name: String) -> CopyContentsGuess {
        let ext = extensionName(name)
        guard !ext.isEmpty else { return .unknown }
        if textExtensions.contains(ext) { return .text }
        guard let type = UTType(filenameExtension: ext), type.isDeclared else { return .unknown }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .text) { return .text }
        return .other
    }

    /// What the file holds, by the bytes ImageIO found in it, when its name doesn't say.
    public static func isImageType(_ identifier: String) -> Bool {
        UTType(identifier).map { $0.conforms(to: .image) } ?? false
    }

    /// Whether the clipboard takes a PNG copy too, for the apps that read only PNG: every image but a PNG or a JPEG.
    public static func needsPNGCopy(_ identifier: String) -> Bool {
        identifier != UTType.png.identifier && identifier != UTType.jpeg.identifier
    }

    /// Text in UTF-8, or in UTF-16 with its byte-order mark; nil for anything else, a file with a zero byte in it among
    /// them, as that is a binary file.
    public static func decodeText(_ data: Data) -> String? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return String(data: data.dropFirst(3), encoding: .utf8) }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        if data.contains(0) { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// A name that usually holds a password or a key: `.env` files, keys and certificates, and private SSH keys (the
    /// public `.pub` ones are meant to be shared).
    public static func looksSecret(_ name: String) -> Bool {
        let lower = name.lowercased()
        if lower == ".env" || lower.hasPrefix(".env.") { return true }
        let ext = extensionName(lower)
        if ext == "pem" || ext == "key" { return true }
        if ext == "pub" { return false }
        return ["id_rsa", "id_ed25519", "id_ecdsa", "id_dsa"].contains { lower.hasPrefix($0) }
    }

    // MARK: Names

    /// The name of the command, in Settings and Help, and in the menus when it isn't known what it would copy.
    public static let commandLabel = "Copy Contents"

    /// What the menus call the command: what it would copy.
    public static func menuTitle(_ guess: CopyContentsGuess?) -> String {
        switch guess?.kind {
        case .image: "Copy Image"
        case .text: "Copy Text"
        case nil: commandLabel
        }
    }

    // MARK: What is said

    /// The toast once it is on the clipboard.
    public static func copiedTitle(_ kind: CopyContentsKind) -> String {
        kind == .image ? "Copied image" : "Copied text"
    }

    /// The toast while a slow disk is read.
    public static let copyingTitle = "Copying\u{2026}"

    // The toasts of a file that can't be copied, its name under them.
    public static let notImageOrTextTitle = "Not an image or text"
    public static let emptyTitle = "The file is empty"
    public static let tooLargeTitle = "Too large to copy"

    public static func tooLargeMessage(_ kind: CopyContentsKind) -> String {
        kind == .image ? "Images up to 100 MB are copied" : "Text up to 10 MB is copied"
    }

    /// The alert when it failed.
    public static func failureTitle(_ kind: CopyContentsKind?) -> String {
        switch kind {
        case .image: "Couldn\u{2019}t Copy the Image"
        case .text: "Couldn\u{2019}t Copy the Text"
        case nil: "Couldn\u{2019}t Copy the Contents"
        }
    }

    public static let notAnImageMessage = "It couldn\u{2019}t be opened as an image."
    public static let unknownEncodingMessage = "Its text isn\u{2019}t in UTF-8 or UTF-16, which are what can be copied."
    public static func unreadableMessage(_ name: String, _ reason: String) -> String {
        "File Trail couldn\u{2019}t read \u{201C}\(name)\u{201D}: \(reason)"
    }
    public static let pasteboardMessage = "File Trail couldn\u{2019}t put it on the clipboard."

    /// Before the text of a file that usually holds a password or a key is copied.
    public static func secretTitle(_ name: String) -> String {
        "\u{201C}\(name)\u{201D} may hold a password or a key. Copy its text?"
    }

    public static let secretMessage =
        "It is marked as private on the clipboard, so apps that keep a history of the clipboard leave it out."
    public static let secretConfirmLabel = "Copy"
}
