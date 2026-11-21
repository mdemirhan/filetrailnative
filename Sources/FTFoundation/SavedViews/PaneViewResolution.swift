import Foundation

/// What a pane shows of the six settings a folder's view can keep, and where each comes from. The one place that
/// decides it: the pane's own settings, the folder's view (its own or one from above), what is changed of that view on
/// screen and not saved, and a tab view's override.
public enum PaneViewResolution {
    /// Where a setting a pane shows comes from.
    public enum Source: String, Codable, Sendable {
        /// What the pane carries from folder to folder (which a tab view sets, once, when applied).
        case pane
        /// The folder's view as saved: its own, or the nearest one above that covers the folders inside.
        case folderView
        /// A change of the folder's view on screen, not saved yet.
        case changeOnScreen
        /// A tab view applied with "Tab View First", while the pane is still in the folder it opened.
        case tabView
    }

    /// The six settings as the pane shows them, each with where it came from.
    public struct Shown: Equatable, Sendable {
        public var keeps: FolderViewKeeps
        public var sources: [FolderViewSetting: Source]
    }

    /// What a pane on `folder` shows. `carried` is what the pane carries, every setting set; `onScreen` the folder's
    /// view as the pane shows it (nil: the folder uses none); `override` what a tab view left on the pane.
    ///
    /// - No override, or one that doesn't hold in `folder`: the folder's view, with what is changed of it on screen,
    ///   for what it keeps; the pane for the rest.
    /// - "Tab View First": the pane for what the tab view kept; for the rest, as with no override.
    /// - "Not Used": the pane for every setting.
    public static func shown(
        carried: FolderViewKeeps, onScreen: FolderViewOnScreen?, override: TabViewOverride?, folder: String?
    ) -> Shown {
        var keeps = carried
        var sources: [FolderViewSetting: Source] = [:]
        for setting in FolderViewSetting.allCases {
            let source = source(of: setting, onScreen: onScreen, override: override, folder: folder)
            if source == .folderView || source == .changeOnScreen, let onScreen {
                keeps.take(setting, from: onScreen.shown)
            }
            sources[setting] = source
        }
        return Shown(keeps: keeps, sources: sources)
    }

    /// Where `setting` comes from, by the rules of `shown`.
    public static func source(
        of setting: FolderViewSetting, onScreen: FolderViewOnScreen?, override: TabViewOverride?, folder: String?
    ) -> Source {
        if let override, override.holds(in: folder), override.covers(setting) {
            return override.choice == .tabViewFirst ? .tabView : .pane
        }
        guard let onScreen, onScreen.shown.keeps(setting) else { return .pane }
        return onScreen.unsaved.contains(setting) ? .changeOnScreen : .folderView
    }

    /// Whether the folder's view (with what is changed of it on screen) decides `setting`.
    public static func folderViewDecides(
        _ setting: FolderViewSetting, onScreen: FolderViewOnScreen?, override: TabViewOverride?, folder: String?
    ) -> Bool {
        let source = source(of: setting, onScreen: onScreen, override: override, folder: folder)
        return source == .folderView || source == .changeOnScreen
    }
}
