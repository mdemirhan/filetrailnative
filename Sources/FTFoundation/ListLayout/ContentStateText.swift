// Port of the texts of ContentState and EmptyState (apps/desktop/src/renderer/components/ContentPane.tsx:2355-2466) and
// the filter state (:546-561), and the cards of styles.css:2972-3050
import Foundation

public enum ContentStateText {
    /// `FOLDER_LOADING_DELAY_MS`: a folder that lists quickly never flashes "Loading…".
    public static let loadingDelayMilliseconds = 400.0

    public static let loading = "Loading…"
    public static let errorTitle = "Couldn’t open this folder"
    public static let noFolder = "Select a folder to see what’s in it."

    public static let fullDiskAccessTitle = "File Trail needs Full Disk Access to show the Trash"
    public static let fullDiskAccessMessage =
        "macOS lets only apps with Full Disk Access see what is in the Trash. Turn on File Trail in Privacy & Security › Full Disk Access (add it with + if it is not in the list), then quit and reopen File Trail."
    public static let openPrivacySettings = "Open Privacy Settings"

    /// "Empty folder", with the hidden items a folder that lists nothing has when hidden files are off.
    public static func empty(path: String, hiddenItemCount: Int) -> String {
        if path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return noFolder }
        if hiddenItemCount > 0 {
            return "Empty folder · \(hiddenItemCount) hidden \(hiddenItemCount == 1 ? "item" : "items")"
        }
        return "Empty folder"
    }

    public static func noMatches(query: String) -> String { "No items match “\(query)”" }
    public static let noMatchesMessage = "Nothing in this folder has that in its name."
    public static let searchSubfolders = "Search Subfolders"
}

/// The cards of the empty, loading and error states (`.content-state` and its variants).
public struct ContentStateLayout: Equatable, Sendable {
    public var paddingVertical: Double
    public var paddingHorizontal: Double
    public var gap: Double
    public var cardMarginHorizontal: Double
    public var cardMarginBottom: Double
    public var emptyPaddingVertical: Double
    public var emptyPaddingHorizontal: Double
    /// `.content-empty` is `min-height: calc(100% - 24px)`.
    public var emptyHeightReduction: Double
    public var actionsTopMargin: Double

    public static let standard = ContentStateLayout(
        paddingVertical: 16, paddingHorizontal: 18, gap: 8, cardMarginHorizontal: 6, cardMarginBottom: 12,
        emptyPaddingVertical: 48, emptyPaddingHorizontal: 24, emptyHeightReduction: 24, actionsTopMargin: 4)
}
