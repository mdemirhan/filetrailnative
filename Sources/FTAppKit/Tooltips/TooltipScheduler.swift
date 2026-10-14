// Port of installTitleTooltips in apps/desktop/src/renderer/lib/titleTooltips.ts: when an app-drawn tooltip shows
import FTFoundation
import Foundation

/// A control that names itself in an app-drawn tooltip: an icon-only button. A control with a visible label, a row,
/// or a control inside a row never adopts this (the original's `findTooltipElement` leaves those alone).
@MainActor
protocol TooltipAnchor: AnyObject {
    /// The tooltip's text as it is now; blank shows nothing.
    var tooltipText: String { get }
    /// A button whose menu is open stays quiet: its tooltip would sit on top of the menu.
    var tooltipIsQuiet: Bool { get }
}

/// Decides when a tooltip shows: 600 ms after the pointer comes to rest on a control, at once when it moves straight
/// on to another within 400 ms of the last one hiding; hidden by a click (the control then stays quiet until the
/// pointer leaves it), a key, a scroll or the pointer leaving the window. The system's own tooltip is never used, so
/// it can't show beside this one.
@MainActor
final class TooltipScheduler {
    typealias Schedule = @MainActor (_ seconds: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> (() -> Void)

    private let now: () -> TimeInterval
    private let schedule: Schedule
    /// Draws the tooltip for the anchor, with its text; called again with new text while it shows.
    var onShow: (TooltipAnchor, String) -> Void = { _, _ in }
    var onHide: () -> Void = {}

    /// The control whose tooltip is waiting to show, or showing.
    private(set) weak var anchor: TooltipAnchor?
    /// After a click, the control stays quiet until the pointer leaves it.
    private weak var quiet: TooltipAnchor?
    private(set) var isShowing = false
    private var cancelTimer: (() -> Void)?
    private var lastHiddenAt = -Double.infinity
    private var installed = true

    init(
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        schedule: @escaping Schedule = TooltipScheduler.mainQueue
    ) {
        self.now = now
        self.schedule = schedule
    }

    static func mainQueue(_ seconds: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> () -> Void {
        let item = DispatchWorkItem { MainActor.assumeIsolated { fire() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
        return { item.cancel() }
    }

    /// The pointer is over `target` (nil: over something that has no tooltip).
    func hover(_ target: TooltipAnchor?) {
        guard installed else { return }
        if let quiet {
            if quiet === target { return }
            self.quiet = nil
        }
        if let anchor, anchor === target { return }
        hide()
        guard let target, !target.tooltipText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        anchor = target
        let delay = now() - lastHiddenAt <= TitleTooltips.warmWindow ? 0 : TitleTooltips.showDelay
        cancelTimer = schedule(delay) { [weak self] in self?.show() }
    }

    /// The pointer moved over the anchor: a text changed meanwhile is taken up.
    func refresh() {
        guard isShowing, let anchor else { return }
        onShow(anchor, anchor.tooltipText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// A press on `target`: the tooltip hides, and the control stays quiet until the pointer leaves it.
    func press(_ target: TooltipAnchor?) {
        let pressed = anchor ?? target
        hide()
        quiet = pressed
    }

    /// A key, a scroll, a drag, or the pointer leaving the window.
    func dismiss() {
        hide()
    }

    func uninstall() {
        hide()
        installed = false
    }

    private func show() {
        cancelTimer = nil
        guard let anchor else {
            hide()
            return
        }
        let text = anchor.tooltipText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !anchor.tooltipIsQuiet else { return }
        isShowing = true
        onShow(anchor, text)
    }

    private func hide() {
        cancelTimer?()
        cancelTimer = nil
        if isShowing {
            isShowing = false
            onHide()
            lastHiddenAt = now()
        }
        anchor = nil
    }
}
