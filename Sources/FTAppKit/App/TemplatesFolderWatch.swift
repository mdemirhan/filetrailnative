import Darwin
import FTFileSystem
import Foundation

/// The Templates folder as File ▸ New File lists it: its files, read again when something is added to it, taken out
/// or renamed, so the menu can be built again (`onChange`). A folder not made yet is watched once it is
/// (`folderMayExist`, after Open Templates Folder or when the app comes to the front).
@MainActor
final class TemplatesFolderWatch {
    let path: String
    private(set) var names: [String]
    var onChange: (() -> Void)?
    private var source: (any DispatchSourceFileSystemObject)?

    init(path: String) {
        self.path = path
        names = NewFileTemplates.names(in: path)
        watch()
    }

    /// The folder may have been made or replaced since: it is watched (again), and read.
    func folderMayExist() {
        watch()
        readAgain()
    }

    private func watch() {
        guard source == nil else { return }
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.folderChanged() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    private func folderChanged() {
        // The folder itself moved or went: what is at its path now is looked at afresh.
        if let event = source?.data, !event.intersection([.rename, .delete]).isEmpty {
            source?.cancel()
            source = nil
            watch()
        }
        readAgain()
    }

    private func readAgain() {
        let now = NewFileTemplates.names(in: path)
        guard now != names else { return }
        names = now
        onChange?()
    }
}
