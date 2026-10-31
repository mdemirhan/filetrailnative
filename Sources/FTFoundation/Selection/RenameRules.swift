// Port of the commit rules of apps/desktop/src/renderer/components/InlineRenameField.tsx (:145-165) and
// hooks/useExplorerActions.ts (:3649-3786)
import Foundation

/// What the inline rename field does with the name in it.
public enum InlineRenameRules {
    public enum Trigger: Sendable { case enter, blur }

    public enum Decision: Equatable, Sendable {
        /// Nothing to rename: the field closes.
        case cancel
        /// The name was refused already: the field stays open to fix it.
        case keepOpen
        /// Hand the name over.
        case submit
    }

    /// `commit`: an unchanged or emptied name means there is nothing to rename; a name already refused is not sent
    /// again until it has been edited (Return keeps the field open, leaving the field gives up).
    public static func decide(draft: String, original: String, refused: String?, trigger: Trigger) -> Decision {
        if draft == original || JSText.trimmed(draft).isEmpty { return .cancel }
        if let refused, draft == refused { return trigger == .blur ? .cancel : .keepOpen }
        return .submit
    }

    /// The app trims spaces around the typed name before checking it; a name equal to the current one closes the field
    /// with nothing renamed (B-SEL-130).
    public static func trimmedName(_ typed: String) -> String { JSText.trimmed(typed) }

    /// A name that begins with "." while hidden files are not shown asks first (B-SEL-135).
    public static func needsDotConfirmation(name: String, hiddenFilesShown: Bool) -> Bool {
        !hiddenFilesShown && name.hasPrefix(".")
    }

    /// Folders, and links to them, whose names are selected whole when renamed. Packages (an app) keep their extension
    /// outside the selection, as files do (`isFolderKind`).
    public static func selectsWholeName(isDirectoryKind: Bool) -> Bool { isDirectoryKind }
}
