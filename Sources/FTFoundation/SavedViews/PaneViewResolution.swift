import Foundation

/// What a pane shows of the six settings a folder's view can keep, and where each comes from. The one place that
/// decides it: the pane's own settings, the folder's view (its own or one from above), and what is changed of that
/// view on screen and not saved.
public enum PaneViewResolution {
    /// Where a setting a pane shows comes from.
    public enum Source: String, Codable, Sendable {
        /// What the pane carries from folder to folder (which a tab view sets, once, when applied).
        case pane
        /// The folder's view as saved: its own, or the nearest one above that covers the folders inside.
        case folderView
        /// A change of the folder's view on screen, not saved yet.
        case changeOnScreen
    }

    /// Where `setting` comes from: the folder's view, with what is changed of it on screen, for what it keeps
    /// (`onScreen`, nil where the folder uses none); the pane for the rest.
    public static func source(of setting: FolderViewSetting, onScreen: FolderViewOnScreen?) -> Source {
        guard let onScreen, onScreen.shown.keeps(setting) else { return .pane }
        return onScreen.unsaved.contains(setting) ? .changeOnScreen : .folderView
    }

    /// Whether the folder's view (with what is changed of it on screen) decides `setting`.
    public static func folderViewDecides(_ setting: FolderViewSetting, onScreen: FolderViewOnScreen?) -> Bool {
        source(of: setting, onScreen: onScreen) != .pane
    }
}
