// Port of quit() and askToStopOperation() of apps/desktop/src/main/explorerWindowController.ts
import AppKit

/// Quitting stops a running copy, move, or delete after the item it is on. While a window is open the person is asked
/// first, and may keep working instead. With every window closed the operation was already told to stop; quitting waits
/// for it either way. What the write coordinator (P3-05) and the windows (P4-02) do is reached through `Hooks`.
@MainActor
public final class QuitCoordinator {
    public struct Hooks {
        /// The kind of the running write operation, if one runs (P3-05's write coordinator).
        public var activeOperation: () -> BusyOperationKind? = { nil }
        /// Shows the question and answers the index of the button chosen. `parent` is the window it hangs from.
        public var showStopQuestion: (StopQuestion, NSWindow?) async -> Int = { _, _ in
            QuitWhileBusy.keepWorkingButtonIndex
        }
        public var anyWindowOpen: () -> Bool = { false }
        public var frontWindow: () -> NSWindow? = { nil }
        /// A second ⌘Q while the question is open: the question comes forward, to be answered first.
        public var bringStopQuestionForward: () -> Void = {}
        /// Records every window's place and size in the store.
        public var recordAllBounds: () -> Void = {}
        public var flushStore: () -> Void = {}
        /// Stops a running operation and waits until it has cleaned up after itself; stops the watchers; flushes the
        /// logger.
        public var shutDown: () async -> Void = {}
        /// The app ends here (`app.exit(0)`).
        public var exit: () -> Void = {}
        public var log: (String) -> Void = { _ in }

        public init() {}
    }

    /// How a call to `quit()` ended.
    public enum Outcome: Equatable, Sendable {
        /// The app was told to exit.
        case exited
        /// The person chose Keep Working.
        case keptWorking
        /// Shutdown was already under way.
        case alreadyShuttingDown
        /// The question was open already; it came forward.
        case questionBroughtForward
    }

    public var hooks: Hooks
    public private(set) var shutdownInProgress = false
    private var stopQuestionOpen = false
    public private(set) var stopQuestionParent: NSWindow?

    public init(hooks: Hooks = Hooks()) {
        self.hooks = hooks
    }

    public var isAskingToStop: Bool { stopQuestionOpen }

    /// `quit`.
    @discardableResult
    public func quit() async -> Outcome {
        if shutdownInProgress { return .alreadyShuttingDown }
        // Asked already: the question comes forward, to be answered first.
        if stopQuestionOpen {
            hooks.bringStopQuestionForward()
            return .questionBroughtForward
        }
        if hooks.anyWindowOpen(), !(await askToStopOperation(.quit, parent: hooks.frontWindow())) {
            return .keptWorking
        }
        if shutdownInProgress { return .alreadyShuttingDown }
        shutdownInProgress = true
        // The store is written now, with the windows as they are, in case stopping the work never ends; and again
        // once it has, with what changed in the open windows meanwhile.
        hooks.recordAllBounds()
        hooks.flushStore()
        await hooks.shutDown()
        hooks.recordAllBounds()
        hooks.flushStore()
        hooks.exit()
        return .exited
    }

    /// `askToStopOperation`: asks whether to stop the running operation, when there is one worth asking about.
    /// True when it may be stopped (or nothing needs asking), false to keep working.
    public func askToStopOperation(_ trigger: StopTrigger, parent: NSWindow?) async -> Bool {
        let kind = hooks.activeOperation()
        guard let kind, let question = QuitWhileBusy.question(kind, trigger: trigger) else { return true }
        stopQuestionOpen = true
        stopQuestionParent = parent
        let response = await hooks.showStopQuestion(question, parent)
        stopQuestionOpen = false
        stopQuestionParent = nil
        if response != QuitWhileBusy.stopButtonIndex {
            hooks.log("kept an operation running instead of stopping it (\(trigger), \(kind.rawValue))")
            return false
        }
        return true
    }
}

/// The question as an alert: Keep Working is the default button and what Escape picks.
@MainActor
enum StopQuestionAlert {
    static func show(_ question: StopQuestion, parent: NSWindow?) async -> Int {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = question.message
        alert.informativeText = question.detail
        for title in question.buttons { alert.addButton(withTitle: title) }
        let keepWorking = alert.buttons.first
        // Escape picks the first button, which Return also picks.
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53, let keepWorking else { return event }
            keepWorking.performClick(nil)
            return nil
        }
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }
        let response: NSApplication.ModalResponse
        if let parent, parent.isVisible {
            response = await alert.beginSheetModal(for: parent)
        } else {
            response = alert.runModal()
        }
        return response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }
}
