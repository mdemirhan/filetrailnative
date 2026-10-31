// The Rename sheet for several items on a window that is never shown, driven as the explorer window drives it: its
// model over a stand-in for the items' checks, its settings read from and saved to a record
import AppKit
import FTFoundation
import FTOperations
import Foundation
import Testing

@testable import FTAppKit

/// A window that hands its events to the app's routing first, as the explorer's tab windows do.
final class BatchRenameTestWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        if WindowEventRouting.intercept(event, in: self) { return }
        super.sendEvent(event)
    }
}

/// The items' checks, answered at once (as `answer` says) or held until a test answers them.
@MainActor
final class BatchRenameInspectBox {
    enum Mode {
        case answer
        case hold
        case fail
    }

    var mode: Mode
    var folderNames: [String]?
    var cannotRename: [String: String] = [:]
    var takenAt: String?
    /// Every request, in order.
    private(set) var requests: [BatchRenameInspectRequest] = []
    private var waiting: [Int: CheckedContinuation<BatchRenameInspection, any Error>] = [:]

    init(mode: Mode = .answer) {
        self.mode = mode
    }

    var inspector: BatchRenameSheetModel.Inspector {
        { [self] request in try await self.inspect(request) }
    }

    func inspect(_ request: BatchRenameInspectRequest) async throws -> BatchRenameInspection {
        requests.append(request)
        let index = requests.count - 1
        switch mode {
        case .answer:
            return Self.answer(
                paths: request.paths, folderNames: folderNames, cannotRename: cannotRename,
                takenAt: request.includeDateTaken ? takenAt : nil)
        case .fail:
            throw OperationError("gone")
        case .hold:
            return try await withCheckedThrowingContinuation { waiting[index] = $0 }
        }
    }

    /// Answers request `index` (held until now), once it has been asked.
    func resolve(_ index: Int, _ answer: BatchRenameInspection) async {
        _ = await waitUntil { self.waiting[index] != nil }
        waiting.removeValue(forKey: index)?.resume(returning: answer)
    }

    /// `answerFor`: what the checks say of these items, all in the folder of the first.
    static func answer(
        paths: [String], folderNames: [String]? = nil, cannotRename: [String: String] = [:], takenAt: String? = nil,
        created: String? = "2026-09-30T10:12:40", modified: String? = "2026-10-01T08:30:15"
    ) -> BatchRenameInspection {
        let folder = paths.first.map(NodePath.dirname) ?? "/"
        return BatchRenameInspection(
            items: paths.map {
                .init(
                    path: $0, createdAt: created, modifiedAt: modified, takenAt: takenAt, cannotRename: cannotRename[$0]
                )
            },
            folders: [.init(path: folder, names: folderNames ?? paths.map(NodePath.basename), caseSensitive: false)])
    }
}

/// The saved settings and presets, and what the model saves.
@MainActor
final class BatchRenameSavedRecord {
    var settings: JSONNode?
    var presets: JSONNode?
    var fails = false
    private(set) var patches: [[String: JSONNode]] = []

    func read() throws -> BatchRenameSheetModel.Saved {
        if fails { throw OperationError("no preferences") }
        return .init(settings: settings, presets: presets)
    }

    func save(_ patch: [String: JSONNode]) { patches.append(patch) }

    /// The settings saved last.
    var savedSettings: BatchRenameSettings? {
        patches.last { $0["batchRenameSettings"] != nil }.map {
            BatchRename.sanitizeSettings($0["batchRenameSettings"])
        }
    }

    /// The presets saved last.
    var savedPresets: [BatchRenamePreset]? {
        patches.last { $0["batchRenamePresets"] != nil }.map { BatchRename.sanitizePresets($0["batchRenamePresets"]) }
    }
}

/// Types `text` into a sheet field, as a person does.
@MainActor
func batchRenameType(_ field: BatchRenameTextField, _ text: String) {
    field.field.stringValue = text
    field.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field.field))
}

/// Chooses the item titled `title` of a sheet pop-up.
@MainActor
func batchRenamePick(_ popUp: BatchRenamePopUp, _ title: String) {
    guard let index = popUp.itemArray.firstIndex(where: { $0.title == title && !$0.isSeparatorItem }) else {
        Issue.record("no “\(title)” in \(popUp.accessibilityLabel() ?? "")")
        return
    }
    popUp.selectItem(at: index)
    if let action = popUp.action { NSApp.sendAction(action, to: popUp.target, from: popUp) }
}

/// A model over the stand-ins.
@MainActor
func makeBatchRenameModel(_ box: BatchRenameInspectBox, _ saved: BatchRenameSavedRecord) -> BatchRenameSheetModel {
    BatchRenameSheetModel(inspector: box.inspector, readSaved: { try saved.read() }, save: { saved.save($0) })
}

/// The sheet on a window that is never shown, as `BatchRenameSheet.test.tsx`'s harness renders it: the items in
/// "/trip", created 2026-09-30T10:12:40 and modified 2026-10-01T08:30:15, the folder holding only them unless told.
@MainActor
final class BatchRenameSheetFixture {
    static let now = "2026-10-04T11:32:10"

    let box: BatchRenameInspectBox
    let saved = BatchRenameSavedRecord()
    let model: BatchRenameSheetModel
    let sheet: BatchRenameSheetView
    let window: NSWindow
    let scrim: DialogScrim
    var renamed: [BatchRenameRequest] = []
    var cancelled = 0

    nonisolated static func target(_ name: String, folder: Bool = false) -> BatchRenameTarget {
        BatchRenameTarget(path: "/trip/\(name)", name: name, isFolder: folder)
    }

    init(
        _ targets: [BatchRenameTarget], folderNames: [String]? = nil, presets: [BatchRenamePreset] = [],
        cannotRename: [String: String] = [:], inspect: BatchRenameInspectBox.Mode = .answer,
        initial: (inout BatchRenameSettings) -> Void = { _ in }
    ) async {
        box = BatchRenameInspectBox(mode: inspect)
        box.folderNames = folderNames
        box.cannotRename = cannotRename
        var settings = BatchRenameSettings.defaults
        initial(&settings)
        saved.settings = BatchRenamePresetList.node(of: settings)
        saved.presets = BatchRenamePresetList.node(of: presets)
        model = makeBatchRenameModel(box, saved)
        model.open(targets, now: AppClock.parse(Self.now) ?? Date())
        sheet = BatchRenameSheetView(model: model)
        window = BatchRenameTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760), styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        scrim = DialogScrim(panel: sheet, placement: .sheet)
        sheet.onCancel = { [unowned self] in self.cancelled += 1 }
        sheet.onRename = { [unowned self] request in self.renamed.append(request) }
        scrim.present(in: window)
        sheet.takeKeyboard()
        if inspect == .answer { _ = await waitUntil { !self.model.checking } }
        layout()
    }

    func layout() {
        window.contentView?.layoutSubtreeIfNeeded()
        scrim.layout()
        sheet.layoutSubtreeIfNeeded()
    }

    func close() {
        scrim.dismiss(restoringFocus: false)
        window.close()
    }

    /// What each row shows, without what is there only for screen readers.
    var rows: [String] { sheet.preview.rows.map(\.shownText) }

    var summary: String { sheet.summaryText }

    /// Types `text` into `field`, as a person does.
    func type(_ field: BatchRenameTextField, _ text: String) {
        batchRenameType(field, text)
        layout()
    }

    /// Chooses the item titled `title` of a pop-up.
    func pick(_ popUp: BatchRenamePopUp, _ title: String) {
        batchRenamePick(popUp, title)
        layout()
    }

    /// The titles a pop-up offers (a pull-down's title not counted, separators as "-").
    func titles(_ popUp: BatchRenamePopUp) -> [String] {
        popUp.itemArray.dropFirst(popUp.pullsDown ? 1 : 0).map { $0.isSeparatorItem ? "-" : $0.title }
    }

    func key(_ code: UInt16, _ characters: String, modifiers: NSEvent.ModifierFlags = []) {
        DialogKeys.press(code, characters, modifiers: modifiers, in: window)
        layout()
    }

    func returnKey() { key(KeyCode.returnKey, "\r") }
    func escape() { key(KeyCode.escape, "\u{1b}") }

    /// The row cell drawing row `index`.
    func cell(_ index: Int) -> BatchRenameRowCell? {
        sheet.preview.table.view(atColumn: 0, row: index, makeIfNecessary: true) as? BatchRenameRowCell
    }
}
