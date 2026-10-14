// Port of apps/desktop/src/renderer/hooks/useEjectVolume.ts and the answers of components/EjectVolumeAlert.tsx
import AppKit
import FTFileSystem

/// What the person answers when asked which volumes of a disk to eject.
enum EjectWhichVolumesAnswer: Equatable, Sendable {
    case all, one, cancel
}

/// What the person answers when a disk is in use.
enum EjectBusyAnswer: Equatable, Sendable {
    case retry, force, cancel
}

/// Where the questions and the notices of an eject are drawn. P6-01 draws the original's alerts; until then they are
/// plain ones with the original's texts.
@MainActor
protocol EjectPresenter: AnyObject {
    /// "Do you want to eject “Name” only, or all N volumes on its disk?" with Eject All (the default), Eject and Cancel.
    func askWhichVolumes(name: String, otherNames: [String], answer: @escaping (EjectWhichVolumesAnswer) -> Void)
    /// "The disk “Name” wasn’t ejected because one or more programs may be using it." with Try Again (the default),
    /// Force Eject and Cancel.
    func askBusy(_ notice: EjectNotice, answer: @escaping (EjectBusyAnswer) -> Void)
    /// A modal notice: the eject failed.
    func show(_ notice: EjectNotice)
}

/// Eject, from a disk's button in Locations, its right-click menu or File ▸ Eject. A disk that shares its physical disk
/// with other volumes asks first, as Finder does; a disk in use asks whether to force it. A request for a disk already
/// being ejected is ignored; the disk's Eject button waits meanwhile.
@MainActor
final class EjectCoordinator {
    private let volumes: () -> [Volume]
    private let eject: (EjectRequest) async -> EjectResponse
    weak var presenter: (any EjectPresenter)?
    /// The disks being ejected changed.
    var onChange: () -> Void = {}
    /// An eject request returned: the volume list is read again.
    var didFinish: () -> Void = {}

    private(set) var ejectingPaths: Set<String> = []

    init(
        volumes: @escaping () -> [Volume],
        eject: @escaping (EjectRequest) async -> EjectResponse = { await EjectOutcome.ejectVolume($0) }
    ) {
        self.volumes = volumes
        self.eject = eject
    }

    /// Ejects the disk at `path`: at once, or after the question when other volumes share its physical disk. Nothing
    /// for a path that is not a listed volume or cannot be ejected.
    func requestEject(path: String) {
        guard let plan = EjectPlanning.planEject(volumes(), path: path) else { return }
        switch plan {
        case .eject(let path):
            Task { await run(path: path, wholeDisk: true, force: false) }
        case .askWhichVolumes(let path, let name, let otherNames):
            presenter?.askWhichVolumes(name: name, otherNames: otherNames) { [weak self] answer in
                self?.answerWhichVolumes(path: path, answer)
            }
        }
    }

    /// Eject All, Eject (this volume only) or Cancel.
    func answerWhichVolumes(path: String, _ answer: EjectWhichVolumesAnswer) {
        guard answer != .cancel else { return }
        Task { await run(path: path, wholeDisk: answer == .all, force: false) }
    }

    /// Force Eject, Try Again or Cancel. Both go on from the volume in use: volumes of the same disk unmounted before it
    /// was refused are gone already.
    func answerBusy(busyPath: String, wholeDisk: Bool, _ answer: EjectBusyAnswer) {
        guard answer != .cancel else { return }
        Task { await run(path: busyPath, wholeDisk: wholeDisk, force: answer == .force) }
    }

    /// Runs one eject and reports how it went. Awaiting it is for tests.
    func run(path: String, wholeDisk: Bool, force: Bool) async {
        guard !ejectingPaths.contains(path) else { return }
        ejectingPaths.insert(path)
        onChange()
        let response = await eject(EjectRequest(path: path, wholeDisk: wholeDisk, force: force))
        ejectingPaths.remove(path)
        onChange()
        switch response.status {
        case .ejected:
            break
        case .busy:
            let busyPath = response.failedPath ?? path
            presenter?.askBusy(EjectPlanning.describeEjectBusy(volumes(), busyPath: busyPath)) { [weak self] answer in
                self?.answerBusy(busyPath: busyPath, wholeDisk: wholeDisk, answer)
            }
        case .failed:
            presenter?.show(
                EjectPlanning.describeEjectFailure(
                    volumes(), path: path, failedPath: response.failedPath, code: response.code, reason: response.reason))
        }
        didFinish()
    }
}

/// The plain alerts for the eject questions, as sheets on a window.
@MainActor
final class AlertEjectPresenter: EjectPresenter {
    private let window: () -> NSWindow?

    init(window: @escaping () -> NSWindow?) {
        self.window = window
    }

    func askWhichVolumes(name: String, otherNames: [String], answer: @escaping (EjectWhichVolumesAnswer) -> Void) {
        let text = EjectPlanning.describeWhichVolumesQuestion(name: name, otherNames: otherNames)
        let alert = NSAlert()
        alert.messageText = text.title
        alert.informativeText = text.message
        alert.addButton(withTitle: "Eject All")
        alert.addButton(withTitle: "Eject")
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\u{1B}"
        present(alert) { response in
            switch response {
            case .alertFirstButtonReturn: answer(.all)
            case .alertSecondButtonReturn: answer(.one)
            default: answer(.cancel)
            }
        }
    }

    func askBusy(_ notice: EjectNotice, answer: @escaping (EjectBusyAnswer) -> Void) {
        let alert = NSAlert()
        alert.messageText = notice.title
        alert.informativeText = notice.message
        alert.addButton(withTitle: "Try Again")
        let force = alert.addButton(withTitle: "Force Eject")
        force.hasDestructiveAction = true
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\u{1B}"
        present(alert) { response in
            switch response {
            case .alertFirstButtonReturn: answer(.retry)
            case .alertSecondButtonReturn: answer(.force)
            default: answer(.cancel)
            }
        }
    }

    func show(_ notice: EjectNotice) {
        let alert = NSAlert()
        alert.messageText = notice.title
        alert.informativeText = notice.message
        alert.addButton(withTitle: "OK")
        present(alert) { _ in }
    }

    private func present(_ alert: NSAlert, _ completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = window() {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }
}
