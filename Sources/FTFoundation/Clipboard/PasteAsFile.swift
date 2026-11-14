import Foundation

/// What Paste as File writes from the system's clipboard: an image or text.
public enum PasteAsFileKind: String, Sendable, Equatable, CaseIterable {
    case image, text
}

/// An image on the system's clipboard, in the order they are taken: the bytes of an encoded image are written as they
/// are, and TIFF, which is large and opens in fewer apps, is written as PNG.
public enum PasteAsFileImageFormat: String, Sendable, Equatable, CaseIterable {
    case png, jpeg, heic, gif, tiff

    /// The clipboard type the image is read as.
    public var typeIdentifier: String {
        switch self {
        case .png: "public.png"
        case .jpeg: "public.jpeg"
        case .heic: "public.heic"
        case .gif: "com.compuserve.gif"
        case .tiff: "public.tiff"
        }
    }

    /// The extension of the file written: a TIFF is written as PNG.
    public var fileExtension: String {
        switch self {
        case .png, .tiff: "png"
        case .jpeg: "jpg"
        case .heic: "heic"
        case .gif: "gif"
        }
    }

    /// Whether the image is converted before it is written, rather than written as it is.
    public var isConverted: Bool { self == .tiff }
}

/// What Paste as File finds on the system's clipboard.
public enum PasteAsFileChoice: Equatable, Sendable {
    case image(PasteAsFileImageFormat)
    case text
    /// Files copied in another app: their icon and name are on the clipboard too, and are never written.
    case files
    case nothing

    /// What a file would be made of; nil when nothing would be.
    public var kind: PasteAsFileKind? {
        switch self {
        case .image: .image
        case .text: .text
        case .files, .nothing: nil
        }
    }
}

/// The rules of Paste as File: what on the system's clipboard becomes a file, what it is named, and what is said.
public enum PasteAsFile {
    /// The plain text type.
    public static let textType = "public.utf8-plain-text"
    /// What Finder and other apps put on the clipboard for files they copy.
    public static let fileTypes: Set<String> = ["public.file-url", "NSFilenamesPboardType"]
    /// The mark password managers put on what they copy, so that clipboard tools keep it to themselves.
    public static let concealedType = "org.nspasteboard.ConcealedType"

    /// What a file would be made of, from the clipboard's types. Files copied elsewhere are never written. Plain text
    /// wins over an image: a copy from a document or a spreadsheet carries a picture of it as well. An image whose only
    /// text is its address (a browser's Copy Image) is the image. `text` reads the plain text, and is asked only then.
    public static func choose(types: [String], text: () -> String?) -> PasteAsFileChoice {
        if types.contains(where: fileTypes.contains) { return .files }
        let image = PasteAsFileImageFormat.allCases.first { types.contains($0.typeIdentifier) }
        if types.contains(textType), let text = text(), !text.isEmpty {
            if let image, isLoneAddress(text) { return .image(image) }
            return .text
        }
        return image.map { .image($0) } ?? .nothing
    }

    /// Whether the clipboard holds what a password manager marked as private.
    public static func isConcealed(types: [String]) -> Bool {
        types.contains(concealedType)
    }

    /// A web or file address alone, with nothing around it but blank space.
    static func isLoneAddress(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace),
            let url = URL(string: trimmed), let scheme = url.scheme?.lowercased()
        else { return false }
        return ["http", "https", "file", "data"].contains(scheme)
    }

    // MARK: Names

    /// The name of the command, in Settings and Help, and in the menus when the clipboard has nothing to paste.
    public static let commandLabel = "Paste as File"

    /// What the menus call the command: what it would write.
    public static func menuTitle(_ kind: PasteAsFileKind?) -> String {
        switch kind {
        case .image: "Paste Image as File"
        case .text: "Paste Text as File"
        case nil: commandLabel
        }
    }

    /// The name a file is given before it is renamed: "Pasted Image.png", "Pasted Text.txt".
    public static func fileName(_ choice: PasteAsFileChoice) -> String? {
        switch choice {
        case .image(let format): "Pasted Image.\(format.fileExtension)"
        case .text: "Pasted Text.txt"
        case .files, .nothing: nil
        }
    }

    /// The name, or the first numbered one ("Pasted Image 2.png") that no item in the folder has, whatever its case.
    public static func freeName(_ name: String, existingNames: [String]) -> String {
        let taken = Set(existingNames.map { $0.lowercased() })
        if !taken.contains(name.lowercased()) { return name }
        for number in 2..<10_000 {
            let candidate = NumberedNames.addNumberToName(name, isFolder: false, separator: " ", number: number).name
            if !taken.contains(candidate.lowercased()) { return candidate }
        }
        return name
    }

    // MARK: What is said

    /// Nothing on the clipboard can be written.
    public static let nothingTitle = "The clipboard has no image or text"
    /// Files copied in another app, which File Trail can't paste.
    public static let filesTitle = "Can\u{2019}t paste files from another app"
    public static let filesMessage = "Drag them in instead"
    /// Before a password manager's private text is written to a file.
    public static let concealedTitle = "The clipboard holds private text, such as a password. Save it in a file?"
    public static let concealedMessage =
        "The app that copied it marked it as private. A file keeps it on the disk until you delete the file."
    public static let concealedConfirmLabel = "Save"
}
