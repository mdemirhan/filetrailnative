// Port of openSettingsWindow, openHelpWindow, openAboutWindow, openAcknowledgementsWindow and showPageWindow in
// apps/desktop/src/main/main.ts
import AppKit
import FTFileSystem
import FTFoundation

/// The windows of the app that are pages of the original's renderer and not explorer windows: Settings, Help, About and
/// Acknowledgements. Each is one at a time: asking again shows and focuses the one open.
@MainActor
public final class PageWindows {
    private let model: AppearanceModel
    private let preferences: () -> AppPreferences
    private var settings: SettingsWindowController?
    private var help: HelpWindowController?
    private var about: AboutWindowController?
    private var acknowledgements: AcknowledgementsWindowController?
    /// The page Help was left on, for the next time it opens.
    public private(set) var lastHelpTopic: HelpTopicID?

    /// The tab Settings was left on, for this session only (`lastSettingsTab`).
    public private(set) var lastSettingsTab: SettingsTab?
    /// Opens Settings on the Shortcuts tab, for Help's "Customize…".
    public lazy var openSettingsOnShortcuts: () -> Void = { [weak self] in self?.openSettings(tab: .shortcuts) }
    /// Reads the preferences Settings shows (`app:getPreferences`); throws when they can't be read.
    public var loadPreferences: (() throws -> AppPreferences)?
    /// Saves what Settings changed (`app:updatePreferences`); false when the write was refused.
    public var writePreferences: (PreferencesPatch) -> Bool = { _ in true }
    /// The pickers and checks Settings uses (tests replace them).
    var settingsServices = SettingsServices()
    public var homePath = FileManager.default.homeDirectoryForCurrentUser.path
    /// The About window's links and clipboard.
    public var aboutActions = AboutActions()
    public var readAboutInfo: () -> AboutInfo? = { AboutInfoReader.read() }
    public var readAcknowledgements: () throws -> [Acknowledgement] = { try Acknowledgements.read() }
    /// Off, its windows are made and read but never go on screen (the windowless tests, as `ExplorerWindows`').
    var presentsWindows = true

    public init(model: AppearanceModel = .shared, preferences: @escaping () -> AppPreferences) {
        self.model = model
        self.preferences = preferences
    }

    // MARK: Windows on screen

    public var settingsWindow: SettingsWindowController? { settings }
    public var helpWindow: HelpWindowController? { help }
    public var aboutWindow: AboutWindowController? { about }
    public var acknowledgementsWindow: AcknowledgementsWindowController? { acknowledgements }

    // MARK: Settings

    /// Settings opens on the tab asked for, or the one it was left on; one already open shows and focuses it, on the tab
    /// asked for if any.
    public func openSettings(tab: SettingsTab? = nil) {
        if let settings {
            if let tab { settings.show(tab: tab) }
            settings.present()
            return
        }
        let read = loadPreferences ?? { [preferences] in preferences() }
        let opening = tab ?? lastSettingsTab ?? .general
        let controller = SettingsWindowController(
            tab: opening, load: read, homePath: homePath,
            write: { [weak self] patch in self?.writePreferences(patch) ?? false }, services: settingsServices,
            model: model)
        controller.onTabChange = { [weak self] in self?.lastSettingsTab = $0 }
        controller.onClose = { [weak self, weak controller] in
            if let controller { self?.lastSettingsTab = controller.activeTab }
            self?.settings = nil
        }
        lastSettingsTab = opening
        settings = controller
        controller.ordersWindow = presentsWindows
        controller.present()
    }

    // MARK: Help

    /// The keys the commands have now (Settings → Shortcuts), and what Return does.
    func shortcutDisplay(_ preferences: AppPreferences) -> ShortcutDisplay {
        ShortcutDisplay(
            shortcuts: ShortcutCommands.resolve(preferences.shortcutOverrides),
            returnKeyAction: preferences.returnKeyAction)
    }

    /// Help opens on the page asked for, or the one it was left on; one already open shows and focuses it, on the page
    /// asked for if any.
    public func openHelp(topic: HelpTopicID? = nil) {
        if let help {
            if let topic { help.show(topic: topic) }
            help.present()
            return
        }
        let controller = HelpWindowController(
            shortcuts: shortcutDisplay(preferences()), topic: topic ?? lastHelpTopic ?? .navigation,
            onTopicChange: { [weak self] in self?.lastHelpTopic = $0 },
            onCustomize: { [weak self] in
                self?.openSettingsOnShortcuts()
            }, model: model)
        controller.onClose = { [weak self] in self?.help = nil }
        help = controller
        controller.ordersWindow = presentsWindows
        controller.present()
    }

    // MARK: About and Acknowledgements

    /// About File Trail: a small fixed window in place of the standard panel.
    public func openAbout() {
        if let about {
            about.present()
            return
        }
        var actions = aboutActions
        actions.openAcknowledgements = { [weak self] in self?.openAcknowledgements() }
        let controller = AboutWindowController(info: readAboutInfo(), actions: actions, model: model)
        controller.onClose = { [weak self] in self?.about = nil }
        about = controller
        controller.ordersWindow = presentsWindows
        controller.present()
    }

    /// The open-source software inside the app and its licenses, opened from About.
    public func openAcknowledgements() {
        if let acknowledgements {
            acknowledgements.present()
            return
        }
        let controller = AcknowledgementsWindowController(load: readAcknowledgements, model: model)
        controller.onClose = { [weak self] in self?.acknowledgements = nil }
        acknowledgements = controller
        controller.ordersWindow = presentsWindows
        controller.present()
    }

    // MARK: Preferences

    /// A preference changed: Settings shows a change made in another window, and Help the keys the commands have now.
    public func preferencesChanged(_ preferences: AppPreferences, _ change: PreferencesChange) {
        settings?.preferencesChanged(change)
        guard change.patch["shortcutOverrides"] != nil || change.patch["returnKeyAction"] != nil else { return }
        help?.helpView.shortcuts = shortcutDisplay(preferences)
    }
}
