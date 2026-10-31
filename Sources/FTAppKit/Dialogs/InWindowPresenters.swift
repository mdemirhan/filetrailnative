// Port of apps/desktop/src/renderer/components/EjectVolumeAlert.tsx and of the notices and the Always Open With question
// of components/AppDialogs.tsx (ActionNoticeDialog, confirmAlwaysOpenWith), drawn in the window
import AppKit
import FTFileSystem
import FTFoundation

/// The eject questions and notices as the original's alerts over the window.
@MainActor
final class InWindowEjectPresenter: EjectPresenter {
    private let window: () -> NSWindow?

    init(window: @escaping () -> NSWindow?) {
        self.window = window
    }

    /// Finder's question for one volume of a disk that holds others: Eject All (the default, on top), Eject, Cancel.
    func askWhichVolumes(name: String, otherNames: [String], answer: @escaping (EjectWhichVolumesAnswer) -> Void) {
        let text = EjectPlanning.describeWhichVolumesQuestion(name: name, otherNames: otherNames)
        ask(
            text.title, text.message,
            [
                AlertButtonSpec("Eject All", .default, answer: EjectWhichVolumesAnswer.all),
                AlertButtonSpec("Eject", answer: .one), AlertButtonSpec("Cancel", answer: .cancel),
            ], escape: .cancel, answer)
    }

    /// A disk in use: Try Again (the default), Force Eject (it destroys nothing open only by force), Cancel.
    func askBusy(_ notice: EjectNotice, answer: @escaping (EjectBusyAnswer) -> Void) {
        ask(
            notice.title, notice.message,
            [
                AlertButtonSpec("Try Again", .default, answer: EjectBusyAnswer.retry),
                AlertButtonSpec("Force Eject", .destructive, answer: .force),
                AlertButtonSpec("Cancel", answer: .cancel),
            ], escape: .cancel, answer)
    }

    func show(_ notice: EjectNotice) {
        guard let window = InWindowAlerts.host(window()) else {
            WriteDialogs.plainNotice(.warning, notice.title, notice.message, nil)
            return
        }
        InWindowAlerts.notice(title: notice.title, message: notice.message, in: window)
    }

    private func ask<Answer: Equatable & Sendable>(
        _ title: String, _ message: String, _ buttons: [AlertButtonSpec<Answer>], escape: Answer,
        _ answer: @escaping (Answer) -> Void
    ) {
        guard let window = InWindowAlerts.host(window()) else {
            answer(escape)
            return
        }
        Task { @MainActor in
            answer(
                await InWindowAlerts.ask(
                    title: title, message: message, buttons: buttons, escape: escape, stacked: true, in: window))
        }
    }
}

/// The notices of the right-click menus and the Always Open With question, as the window's alerts.
@MainActor
final class InWindowNoticePresenter: ActionNoticePresenting {
    func show(title: String, message: String, in window: NSWindow?) {
        WriteDialogs.drawNotice(title, message, window, style: .warning)
    }

    /// Finder's question, word for word, then what it changes; Change All is the default.
    func confirmAlwaysOpenWith(appName: String, kindName: String?, in window: NSWindow?) async -> Bool {
        await WriteDialogs.drawQuestion(
            WriteQuestion(
                title: ActionNoticeText.alwaysOpenWithTitle(appName: appName),
                message: ActionNoticeText.alwaysOpenWithMessage(kindName: kindName), confirmLabel: "Change All",
                destructive: false, cancelIsDefault: false), window)
    }
}
