// Port of planBatchRename and its helpers in apps/desktop/src/shared/batchRename.ts
import Foundation

extension BatchRename {
    // Past this many, a number is given without looking further (a folder can't hold that many names like it in
    // practice).
    private static let maxAddedNumber = 100_000

    /// Every item's new name, with clashes settled as the setting says: a number added (" 2", " 3"), the item left as
    /// it is, or the rename held until the name is changed. A name is taken when another item in its folder has it,
    /// or will have it once the rename is done; an item in the batch that changes its name gives its old one up, so
    /// names can be swapped. Items keep their order: the first to ask for a name gets it.
    public static func planBatchRename(_ input: BatchRenamePlanInput) -> BatchRenamePlan {
        let proposed = proposeNames(settings: input.settings, items: input.items, now: input.now)
        var plan = [BatchRenamePlanItem](repeating: .unchanged, count: input.items.count)
        // Each item's place in the batch, grouped by the folder it is in, in the order the folders first appear.
        var folderOrder: [NameKeys.Exact] = []
        var folderPaths: [NameKeys.Exact: String] = [:]
        var byFolder: [NameKeys.Exact: [Int]] = [:]
        for (index, item) in input.items.enumerated() {
            let path = parentPath(of: item.path)
            let key = NameKeys.Exact(path)
            if byFolder[key] == nil {
                folderOrder.append(key)
                folderPaths[key] = path
            }
            byFolder[key, default: []].append(index)
        }
        // Dictionaries keyed by path compare strings by canonical equivalence; the original compares them exactly.
        var folders: [NameKeys.Exact: BatchRenameFolder] = [:]
        for (path, folder) in input.folders { folders[NameKeys.Exact(path)] = folder }
        var cannotRename: [NameKeys.Exact: String] = [:]
        for (path, message) in input.cannotRename { cannotRename[NameKeys.Exact(path)] = message }

        for folderKey in folderOrder {
            let entries = byFolder[folderKey] ?? []
            let folder = folders[folderKey]
            let caseSensitive = folder?.caseSensitive ?? false
            func key(_ name: String) -> NameKeys.Exact {
                NameKeys.Exact(NameKeys.nameKey(name, caseSensitive: caseSensitive))
            }
            // Items that stay as they are, whatever happens: their names stay taken.
            var leftAsIs = Set<Int>()
            for index in entries {
                let item = input.items[index]
                guard case .renamed(let name, let segments, _, let emptyName) = proposed.names[index] else {
                    leftAsIs.insert(index)
                    continue
                }
                let invalid = emptyName ? "The name can\u{2019}t be only an extension." : ItemNames.error(for: name)
                let locked = cannotRename[NameKeys.Exact(item.path)]
                if invalid != nil || locked != nil {
                    plan[index] = .problem(
                        proposedName: name, segments: segments,
                        problem: invalid.map { .invalid(message: $0) } ?? .cannotRename(message: locked ?? ""))
                    leftAsIs.insert(index)
                }
            }
            var taken = Set((folder?.names ?? []).map(key))
            // The number to try first for each name wanted more than once: names are only ever added to `taken`,
            // so the numbers below the last one given stay taken.
            var nextNumber: [NameKeys.Exact: Int] = [:]
            // The names given to items of the batch so far, and the item given each.
            var given: [NameKeys.Exact: Int] = [:]
            // Items skipped for a clash: they keep their old names.
            var skipped: [Int] = []
            for index in entries {
                if leftAsIs.contains(index) {
                    taken.insert(key(input.items[index].name))
                } else {
                    taken.remove(key(input.items[index].name))
                }
            }
            for index in entries {
                let item = input.items[index]
                guard !leftAsIs.contains(index),
                    case .renamed(let name, let segments, let usedCreated, _) = proposed.names[index]
                else { continue }
                let wanted = key(name)
                if !taken.contains(wanted) {
                    taken.insert(wanted)
                    given[wanted] = index
                    plan[index] = renamed(
                        item, name: name, segments: segments, usedCreatedForTaken: usedCreated, addedNumber: nil,
                        numberedForItemInBatch: false)
                    continue
                }
                let byItemInBatch = given[wanted] != nil
                switch input.settings.onConflict {
                case .number:
                    let numbered = findNumberedName(
                        name: name, segments: segments, item: item, settings: input.settings,
                        firstNumber: nextNumber[wanted] ?? 2, isTaken: { taken.contains(key($0)) })
                    taken.insert(key(numbered.name))
                    given[key(numbered.name)] = index
                    nextNumber[wanted] = numbered.number + 1
                    let tooLong = ItemNames.error(for: numbered.name)
                    // "File 1 2.jpg" asking for the taken "File 1.jpg" is numbered back to its own name: it stays
                    // as it is.
                    if sameAfterNFC(numbered.name, item.name) {
                        plan[index] = .unchanged
                        continue
                    }
                    plan[index] =
                        tooLong == nil
                        ? renamed(
                            item, name: numbered.name, segments: numbered.segments, usedCreatedForTaken: usedCreated,
                            addedNumber: numbered.number, numberedForItemInBatch: byItemInBatch)
                        : .problem(
                            proposedName: numbered.name, segments: numbered.segments,
                            problem: .invalid(message: tooLong ?? ""))
                case .skip, .block:
                    let skip = input.settings.onConflict == .skip
                    plan[index] = .problem(
                        proposedName: name, segments: segments,
                        problem: skip ? .skippedTaken(byItemInBatch: byItemInBatch) : .taken(byItemInBatch: byItemInBatch)
                    )
                    if skip { skipped.append(index) }
                }
            }
            // An item skipped for a clash keeps its old name, so the item given that name finds it taken and is
            // skipped too, keeping its own old name in turn, and so on along the chain. Nothing else changes: the
            // other items' names stay free.
            while let next = skipped.popLast() {
                guard let holder = given[key(input.items[next].name)],
                    case .renamed(let name, let segments, _, _) = proposed.names[holder]
                else { continue }
                plan[holder] = .problem(
                    proposedName: name, segments: segments, problem: .skippedTaken(byItemInBatch: false))
                skipped.append(holder)
            }
        }

        var renameCount = 0
        var unchangedCount = 0
        var skippedCount = 0
        var blockingCount = 0
        for item in plan {
            switch item {
            case .rename: renameCount += 1
            case .unchanged: unchangedCount += 1
            case .problem(_, _, let problem):
                switch problem {
                case .skippedTaken, .cannotRename: skippedCount += 1
                case .invalid, .taken: blockingCount += 1
                }
            }
        }
        return BatchRenamePlan(
            settingsError: proposed.settingsError, items: plan, renameCount: renameCount,
            unchangedCount: unchangedCount, skippedCount: skippedCount, blockingCount: blockingCount)
    }

    private static func renamed(
        _ item: BatchRenameItem, name: String, segments: [NameSegment], usedCreatedForTaken: Bool, addedNumber: Int?,
        numberedForItemInBatch: Bool
    ) -> BatchRenamePlanItem {
        .rename(
            name: name, segments: segments, addedNumber: addedNumber, numberedForItemInBatch: numberedForItemInBatch,
            usedCreatedForTaken: usedCreatedForTaken,
            becomesHidden: name.utf8.first == 0x2E && item.name.utf8.first != 0x2E)
    }

    // The name with the first free number added before its extension: "Lisbon 2.jpg". Format numbers with the
    // separator it uses; other modes with a space, as macOS numbers copies.
    private static func findNumberedName(
        name: String, segments: [NameSegment], item: BatchRenameItem, settings: BatchRenameSettings,
        firstNumber: Int, isTaken: (String) -> Bool
    ) -> (name: String, segments: [NameSegment], number: Int) {
        let separator = settings.mode == .format && settings.separator != .none ? settings.separator.rawValue : " "
        func candidate(_ number: Int) -> NumberedNames.Numbered {
            NumberedNames.addNumberToName(name, isFolder: item.isFolder, separator: separator, number: number)
        }
        var number = firstNumber
        while isTaken(candidate(number).name) && number < maxAddedNumber {
            number += 1
        }
        let numbered = candidate(number)
        return (
            numbered.name, mergeSegments(
                splitSegments(segments, at: numbered.keptStemLength).before
                    + [NameSegment(text: "\(separator)\(number)", changed: true)]
                    + splitSegments(segments, at: numbered.stemLength).after),
            number
        )
    }

    private static func splitSegments(_ segments: [NameSegment], at offset: Int) -> (
        before: [NameSegment], after: [NameSegment]
    ) {
        var before: [NameSegment] = []
        var after: [NameSegment] = []
        var position = 0
        for segment in segments {
            let units = Array(segment.text.utf16)
            let end = position + units.count
            if end <= offset {
                before.append(segment)
            } else if position >= offset {
                after.append(segment)
            } else {
                let cut = offset - position
                before.append(NameSegment(text: JSString.string(units[..<cut]), changed: segment.changed))
                after.append(NameSegment(text: JSString.string(units[cut...]), changed: segment.changed))
            }
            position = end
        }
        return (before, after)
    }
}
