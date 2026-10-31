// Port of apps/desktop/src/renderer/hooks/useBatchRename.ts
import FTFoundation
import FTOperations
import Foundation

/// An item the sheet renames, as the list knows it (`BatchRenameTarget`).
struct BatchRenameTarget: Equatable, Sendable {
    var path: String
    var name: String
    /// A folder (or a link to one) has no extension: its whole name is its name.
    var isFolder: Bool
}

/// The Rename sheet for several items: what is shown, its settings (as last used) and saved presets, and the plan
/// built from them. Settings and presets are read when the sheet opens and saved with the app's preferences.
@MainActor
final class BatchRenameSheetModel {
    struct Sheet: Equatable {
        var targets: [BatchRenameTarget]
        /// When the sheet opened, for Today.
        var now: LocalDateTime
        /// What the items' checks found; nil while they are being asked.
        var inspect: BatchRenameInspection?
        /// Whether `inspect` includes the dates taken (asked for only when they are used).
        var inspectHasDatesTaken: Bool
        /// The checks couldn't be made: nothing can be renamed.
        var inspectError: String?
    }

    /// What was saved: the settings and presets as the preferences hold them.
    struct Saved {
        var settings: JSONNode?
        var presets: JSONNode?
    }

    typealias Inspector = @Sendable (BatchRenameInspectRequest) async throws -> BatchRenameInspection

    private let inspector: Inspector
    private let readSaved: @MainActor () throws -> Saved
    private let save: @MainActor ([String: JSONNode]) -> Void
    private let log: @MainActor (String) -> Void

    private(set) var sheet: Sheet? { didSet { changed() } }
    private(set) var settings = BatchRenameSettings.defaults { didSet { changed() } }
    private(set) var presets: [BatchRenamePreset] = [] { didSet { changed() } }
    private var inspectRequest = 0
    private var cachedPlan: BatchRenamePlan?
    /// Told after every change of what the sheet shows.
    var onChange: () -> Void = {}

    init(
        inspector: @escaping Inspector, readSaved: @escaping @MainActor () throws -> Saved,
        save: @escaping @MainActor ([String: JSONNode]) -> Void, log: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        self.inspector = inspector
        self.readSaved = readSaved
        self.save = save
        self.log = log
    }

    private func changed() {
        cachedPlan = nil
        onChange()
    }

    /// Whether the settings use the dates taken (Format, Name and Date, Date Taken).
    static func needsDatesTaken(_ settings: BatchRenameSettings) -> Bool {
        settings.mode == .format && settings.nameFormat == .date && settings.dateSource == .taken
    }

    // MARK: Opening and closing

    /// Opens the sheet on `targets` (none: no sheet), with the settings last used and the presets saved; a failed read
    /// opens it with the defaults and is only logged. The items are checked at once.
    func open(_ targets: [BatchRenameTarget], now: Date = AppClock.now) {
        guard !targets.isEmpty else { return }
        var loaded = BatchRenameSettings.defaults
        do {
            let saved = try readSaved()
            loaded = BatchRename.sanitizeSettings(saved.settings)
            presets = BatchRename.sanitizePresets(saved.presets)
        } catch {
            log("batch rename settings could not be read: \(error)")
        }
        settings = loaded
        sheet = Sheet(
            targets: targets, now: BatchRename.toLocalDateTime(now), inspect: nil, inspectHasDatesTaken: false,
            inspectError: nil)
        inspect(targets, includeDateTaken: Self.needsDatesTaken(loaded))
    }

    /// Closes the sheet: what was typed is kept for next time, whether or not anything was renamed; an answer still
    /// on its way is dropped.
    func close() {
        inspectRequest += 1
        saveSettings(settings)
        sheet = nil
    }

    // MARK: Settings

    func setSettings(_ next: BatchRenameSettings) {
        guard next != settings else { return }
        settings = next
        askForDatesTakenIfUsed()
    }

    /// Dates taken are read from the files, so only once they are used: the answer in hand is dropped and the items
    /// are asked again, once (not while an answer is awaited).
    private func askForDatesTakenIfUsed() {
        guard var current = sheet, Self.needsDatesTaken(settings), !current.inspectHasDatesTaken,
            current.inspect != nil
        else { return }
        current.inspect = nil
        sheet = current
        inspect(current.targets, includeDateTaken: true)
    }

    private func inspect(_ targets: [BatchRenameTarget], includeDateTaken: Bool) {
        inspectRequest += 1
        let requestId = inspectRequest
        let request = BatchRenameInspectRequest(paths: targets.map(\.path), includeDateTaken: includeDateTaken)
        let inspector = inspector
        Task { @MainActor [weak self] in
            let outcome: Result<BatchRenameInspection, any Error>
            do {
                outcome = .success(try await inspector(request))
            } catch {
                outcome = .failure(error)
            }
            guard let self, self.inspectRequest == requestId, var current = self.sheet else { return }
            switch outcome {
            case .success(let answer):
                current.inspect = answer
                current.inspectHasDatesTaken = includeDateTaken
                self.sheet = current
                self.askForDatesTakenIfUsed()
            case .failure(let error):
                self.log("batch rename inspection failed: \(error)")
                current.inspectError = BatchRenameSheetText.inspectFailure
                self.sheet = current
            }
        }
    }

    private func saveSettings(_ next: BatchRenameSettings) {
        save(["batchRenameSettings": BatchRenamePresetList.node(of: next)])
    }

    // MARK: Presets

    /// Saves the settings as they are under `name`, replacing a preset of that name. Presets are saved at once.
    func savePreset(_ name: String) {
        guard let next = BatchRenamePresetList.saving(name, settings: settings, in: presets) else { return }
        savePresets(next)
    }

    func deletePreset(_ name: String) {
        savePresets(BatchRenamePresetList.deleting(name, from: presets))
    }

    private func savePresets(_ next: [BatchRenamePreset]) {
        presets = next
        save(["batchRenamePresets": BatchRenamePresetList.node(of: next)])
    }

    // MARK: The plan

    /// The items are being read (their dates, their folders' names).
    var checking: Bool { sheet.map { $0.inspect == nil && $0.inspectError == nil } ?? false }

    /// The new names, rebuilt from the settings and what the checks found (the names alone until they answer).
    var plan: BatchRenamePlan? {
        if let cachedPlan { return cachedPlan }
        guard let sheet else { return nil }
        let answer = sheet.inspect
        var itemsByPath: [String: BatchRenameInspection.Item] = [:]
        for item in answer?.items ?? [] { itemsByPath[item.path] = item }
        let items = sheet.targets.map { target in
            let inspected = itemsByPath[target.path]
            return BatchRenameItem(
                path: target.path, name: target.name, isFolder: target.isFolder, createdAt: inspected?.createdAt,
                modifiedAt: inspected?.modifiedAt, takenAt: inspected?.takenAt)
        }
        var folders: [String: BatchRenameFolder] = [:]
        for folder in answer?.folders ?? [] {
            folders[folder.path] = BatchRenameFolder(names: folder.names, caseSensitive: folder.caseSensitive)
        }
        var cannotRename: [String: String] = [:]
        for item in answer?.items ?? [] {
            if let reason = item.cannotRename { cannotRename[item.path] = reason }
        }
        let made = BatchRename.planBatchRename(
            BatchRenamePlanInput(
                settings: settings, items: items, folders: folders, cannotRename: cannotRename, now: sheet.now))
        cachedPlan = made
        return made
    }

    /// What to ask the file operations to do, when the plan can be carried out: only the items to rename, with their
    /// final names and whether each is a folder, the conflict choice, and the separator a number added later takes.
    var request: BatchRenameRequest? {
        guard let sheet, let plan, sheet.inspect != nil, sheet.inspectError == nil, plan.settingsError == nil,
            plan.blockingCount == 0, plan.renameCount > 0
        else { return nil }
        let items = plan.items.enumerated().compactMap { index, item -> BatchRenameRequest.Item? in
            guard case .rename(let name, _, _, _, _, _) = item, sheet.targets.indices.contains(index) else {
                return nil
            }
            let target = sheet.targets[index]
            return BatchRenameRequest.Item(sourcePath: target.path, destinationName: name, isFolder: target.isFolder)
        }
        let separator = settings.mode == .format ? settings.separator : .space
        return BatchRenameRequest(
            items: items, onConflict: settings.onConflict,
            numberSeparator: separator == .hyphen || separator == .underscore ? separator.rawValue : " ")
    }

    var canRename: Bool { request != nil }
}
