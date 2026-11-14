import AppKit
import FTFoundation

/// Copy Contents for one window: puts a file's image or text on the system's clipboard, to paste in another app. It
/// asks first for a file that usually holds a password or a key, says when a slow disk holds it up, and the copy asked
/// for last is the one that lands.
@MainActor
final class CopyContentsAction {
    /// The system's clipboard (the one Paste as File reads).
    var pasteboard: () -> NSPasteboard
    var window: () -> NSWindow?
    var toasts: () -> ToastCenter?
    var notices: any ActionNoticePresenting = InWindowNoticePresenter()
    var confirm: @MainActor (_ question: WriteQuestion, _ window: NSWindow?) async -> Bool = { question, window in
        await WriteDialogs.drawQuestion(question, window)
    }
    var read: (_ path: String, _ guess: CopyContentsGuess) async -> Result<FileContents, FileContents.Failure> = {
        await FileContents.read($0, guess: $1)
    }
    /// How long a read runs before "Copying…" is shown.
    var slowDelay: Duration = .milliseconds(500)

    /// Counts the copies asked for: one that finds a later one asked for drops what it read.
    private var generation = 0
    private var copyingToast: String?

    init(
        pasteboard: @escaping () -> NSPasteboard, window: @escaping () -> NSWindow?,
        toasts: @escaping () -> ToastCenter?
    ) {
        self.pasteboard = pasteboard
        self.window = window
        self.toasts = toasts
    }

    static func secretQuestion(_ name: String) -> WriteQuestion {
        WriteQuestion(
            title: CopyContents.secretTitle(name), message: CopyContents.secretMessage,
            confirmLabel: CopyContents.secretConfirmLabel, destructive: false, cancelIsDefault: true)
    }

    /// Copies the file at `path`; true once it is on the clipboard. `announce` off leaves out the toast that says so,
    /// for the Info panel, whose button says "Copied" instead.
    @discardableResult
    func copy(_ path: String, announce: Bool = true) async -> Bool {
        generation += 1
        let mine = generation
        let name = NodePath.basename(path)
        let guess = CopyContents.guess(forName: name)
        let concealed = CopyContents.looksSecret(name)
        if concealed {
            guard await confirm(Self.secretQuestion(name), window()), mine == generation else { return false }
        }
        endCopyingToast()
        let slow = Task { @MainActor [weak self, slowDelay] in
            try? await Task.sleep(for: slowDelay)
            guard !Task.isCancelled, let self, mine == self.generation else { return }
            self.copyingToast = self.toasts()?.push(.info, title: CopyContents.copyingTitle, message: name)
        }
        let result = await read(path, guess)
        slow.cancel()
        // A later copy took over: what it reads is what lands.
        guard mine == generation else { return false }
        endCopyingToast()
        switch result {
        case .success(let contents):
            guard contents.write(to: pasteboard(), concealed: concealed) else {
                notices.show(
                    title: CopyContents.failureTitle(contents.kind), message: CopyContents.pasteboardMessage,
                    in: window())
                return false
            }
            if announce { toasts()?.push(.success, title: CopyContents.copiedTitle(contents.kind), message: name) }
            return true
        case .failure(let failure):
            report(failure, name: name, guess: guess)
            return false
        }
    }

    private func endCopyingToast() {
        if let id = copyingToast { toasts()?.dismiss(id) }
        copyingToast = nil
    }

    /// What can't be copied by its nature is said in a toast; what went wrong reading it, in an alert.
    private func report(_ failure: FileContents.Failure, name: String, guess: CopyContentsGuess) {
        let title = CopyContents.failureTitle(guess.kind)
        switch failure {
        case .tooLarge(let kind):
            toasts()?.push(.info, title: CopyContents.tooLargeTitle, message: CopyContents.tooLargeMessage(kind))
        case .empty:
            toasts()?.push(.info, title: CopyContents.emptyTitle, message: name)
        case .notImageOrText:
            toasts()?.push(.info, title: CopyContents.notImageOrTextTitle, message: name)
        case .notAnImage:
            notices.show(title: title, message: CopyContents.notAnImageMessage, in: window())
        case .unknownEncoding:
            notices.show(title: title, message: CopyContents.unknownEncodingMessage, in: window())
        case .unreadable(let reason):
            notices.show(title: title, message: CopyContents.unreadableMessage(name, reason), in: window())
        }
    }
}
