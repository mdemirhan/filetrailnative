// Port of apps/desktop/src/renderer/HelpWindowApp.tsx and openHelpWindow in apps/desktop/src/main/main.ts
import AppKit
import FTFoundation

/// The Help window (900 by 680, at least 560 by 420): Help's topics beside the files instead of in their place. It follows
/// the app's theme and accent, and shows each command with the keys it has now.
@MainActor
public final class HelpWindowController: PageWindowController {
    public static let size = NSSize(width: 900, height: 680)
    public static let minSize = NSSize(width: 560, height: 420)
    public static let title = "File Trail Help"

    public let helpView: HelpView

    /// `onTopicChange` is told the page on screen, so the app can open Help on it next time. `onCustomize` opens
    /// Settings → Shortcuts.
    public init(
        shortcuts: ShortcutDisplay, topic: HelpTopicID, onTopicChange: @escaping (HelpTopicID) -> Void,
        onCustomize: @escaping () -> Void, model: AppearanceModel = .shared
    ) {
        // Help's sidebar runs the window's full height, under the traffic lights: 52 down is where its content starts.
        helpView = HelpView(shortcuts: shortcuts, initialTopic: topic, topInset: 52, theme: model.theme)
        helpView.onTopicChange = onTopicChange
        helpView.onCustomizeShortcuts = onCustomize
        super.init(
            spec: PageWindowSpec(title: Self.title, size: Self.size, minSize: Self.minSize), model: model)
        window?.contentView = helpView
        window?.initialFirstResponder = helpView
        window?.setContentSize(Self.size)
        themeChanged(model.theme)
        helpView.announceTopic()
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// A page asked for while the window is open replaces the view: the search text and the scroll are reset.
    public func show(topic: HelpTopicID) {
        helpView.show(topic: topic)
    }
}
