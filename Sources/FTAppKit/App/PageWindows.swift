// Port of openHelpWindow, openAboutWindow, openAcknowledgementsWindow and showPageWindow in apps/desktop/src/main/main.ts
import AppKit
import FTFileSystem
import FTFoundation

/// The windows of the app that are pages of the original's renderer and not explorer windows: Help, About and
/// Acknowledgements (Settings is P6-04's). Each is one at a time: asking again shows and focuses the one open.
@MainActor
public final class PageWindows {
    private let model: AppearanceModel
    private let preferences: () -> AppPreferences
    private var help: HelpWindowController?
    private var about: AboutWindowController?
    private var acknowledgements: AcknowledgementsWindowController?
    /// The page Help was left on, for the next time it opens.
    public private(set) var lastHelpTopic: HelpTopicID?

    /// Opens Settings, on the Shortcuts tab for Help's "Customize…". P6-04 replaces the default.
    public var openSettingsOnShortcuts: () -> Void = {}
    /// The About window's links and clipboard.
    public var aboutActions = AboutActions()
    public var readAboutInfo: () -> AboutInfo? = { AboutInfoReader.read() }
    public var readAcknowledgements: () throws -> [Acknowledgement] = { try Acknowledgements.read() }

    public init(model: AppearanceModel = .shared, preferences: @escaping () -> AppPreferences) {
        self.model = model
        self.preferences = preferences
    }

    // MARK: Windows on screen

    public var helpWindow: HelpWindowController? { help }
    public var aboutWindow: AboutWindowController? { about }
    public var acknowledgementsWindow: AcknowledgementsWindowController? { acknowledgements }

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
        controller.present()
    }

    // MARK: Preferences

    /// A preference changed: Help shows the keys the commands have now.
    public func preferencesChanged(_ preferences: AppPreferences, _ change: PreferencesChange) {
        guard change.patch["shortcutOverrides"] != nil || change.patch["returnKeyAction"] != nil else { return }
        help?.helpView.shortcuts = shortcutDisplay(preferences)
    }
}
