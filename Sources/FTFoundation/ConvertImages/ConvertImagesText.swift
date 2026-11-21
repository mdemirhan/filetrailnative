import Foundation

/// What Convert Images says: its menus, its sheet and why a picture wasn't converted.
public enum ConvertImagesText {
    /// The name of the command, in Settings, Help and the menus.
    public static let commandLabel = "Convert Images\u{2026}"
    /// The command's name without its dots, as Undo and the progress card name it.
    public static let actionName = "Convert Images"

    /// "Convert Image…" for one, "Convert 3 Images…" for several, as the menus name what it would convert.
    public static func menuTitle(count: Int) -> String {
        count == 1
            ? "Convert Image\u{2026}" : count > 1 ? "Convert \(FormatLocale.count(count)) Images\u{2026}" : commandLabel
    }

    // MARK: Why one wasn't converted

    public static let notAnImage = "It couldn\u{2019}t be opened as an image."

    public static func tooSmall(_ size: PixelSize) -> String {
        "It is \(size.text), smaller than the size asked for."
    }

    public static func notWritten(_ format: ImageFormat) -> String {
        "It couldn\u{2019}t be written as \(format.title)."
    }

    /// The end of "Stopped after 3 items were converted."
    public static let stoppedDone = "converted"
}
