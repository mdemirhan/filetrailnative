// Add to Copied Items and Add to Cut Items: what an Add would do, worked out before anything changes so a clash of
// names can be asked about first, and the clipboard once it is done
import Foundation

/// An item an Add puts on the clipboard whose name another item there has (`ClipboardAddPlan`).
public struct ClipboardNameClash: Equatable, Sendable {
    /// The item being added.
    public var path: String
    /// The item of its name on the clipboard already, or added before it by the same Add.
    public var otherPath: String

    public init(path: String, otherPath: String) {
        self.path = path
        self.otherPath = otherPath
    }
}

/// What the person answers about the items an Add brings whose names others on the clipboard have.
public enum ClipboardClashAnswer: Equatable, Sendable {
    /// Both stay; the one added is pasted under a name of its own.
    case keepBoth
    /// The one added stays, and the other of its name comes off.
    case useThisOne
    /// The items whose names clash are left off; the rest of the selection is added.
    case dontAdd
}

/// What an Add of `paths` to the clipboard would do (`ClipboardRules.planAdd`).
public struct ClipboardAddPlan: Equatable, Sendable {
    public var mode: ClipboardMode
    /// Items not on the clipboard, in the order they are added.
    public var added: [String]
    /// Items on the clipboard with the other intent: they switch to this one.
    public var switched: [String]
    /// Items on the clipboard with this intent already: nothing changes for them.
    public var alreadyThere: [String]
    /// Items on the clipboard inside a folder being added: they come off, and go with the folder.
    public var absorbed: [String]
    /// Items inside a folder on the clipboard: left off, as they go with it already.
    public var insideListed: [(path: String, folder: String)]
    /// Items added whose names others have: asked about before anything changes.
    public var clashes: [ClipboardNameClash]
    /// What is known of each item added.
    public var entries: [String: ClipboardSourceEntry]

    public static func == (lhs: ClipboardAddPlan, rhs: ClipboardAddPlan) -> Bool {
        lhs.mode == rhs.mode && lhs.added == rhs.added && lhs.switched == rhs.switched
            && lhs.alreadyThere == rhs.alreadyThere && lhs.absorbed == rhs.absorbed
            && lhs.insideListed.map(\.path) == rhs.insideListed.map(\.path)
            && lhs.insideListed.map(\.folder) == rhs.insideListed.map(\.folder) && lhs.clashes == rhs.clashes
            && lhs.entries == rhs.entries
    }

    /// Nothing would change: every item is on the clipboard already with this intent, or inside a folder there.
    public var changesNothing: Bool { added.isEmpty && switched.isEmpty }
}

/// What an Add did, for the toast that says so (`ClipboardTexts.addMessage`).
public struct ClipboardAddReport: Equatable, Sendable {
    public var mode: ClipboardMode
    public var added: [String]
    public var switched: [String]
    public var alreadyThere: [String]
    /// Items that came off as they are inside a folder added.
    public var absorbed: [String]
    public var insideListed: [(path: String, folder: String)]
    /// Items added beside another of their name: pasted under a name of their own.
    public var keptBoth: [String]
    /// Items that came off for one added of their name (Use This One).
    public var replacedOnClipboard: [String]
    /// Items left off as their names clashed (Don't Add).
    public var leftOff: [String]
    /// The clipboard was empty: the Add was a Copy or a Cut.
    public var startedClipboard: Bool

    public static func == (lhs: ClipboardAddReport, rhs: ClipboardAddReport) -> Bool {
        lhs.mode == rhs.mode && lhs.added == rhs.added && lhs.switched == rhs.switched
            && lhs.alreadyThere == rhs.alreadyThere && lhs.absorbed == rhs.absorbed
            && lhs.insideListed.map(\.path) == rhs.insideListed.map(\.path)
            && lhs.insideListed.map(\.folder) == rhs.insideListed.map(\.folder) && lhs.keptBoth == rhs.keptBoth
            && lhs.replacedOnClipboard == rhs.replacedOnClipboard && lhs.leftOff == rhs.leftOff
            && lhs.startedClipboard == rhs.startedClipboard
    }
}

extension ClipboardRules {
    /// What adding `paths` with `mode` would do. Nothing is changed: a clash of names is asked about first.
    public static func planAdd(
        _ clipboard: CopyPasteClipboard, _ mode: ClipboardMode, _ paths: [String],
        entries: [String: ClipboardSourceEntry] = [:]
    ) -> ClipboardAddPlan {
        let picked = Paths.withoutNestedPaths(paths.filter { !$0.isEmpty })
        let picks = clipboard.picks
        let onClipboard = Dictionary(picks.map { (ExactKey($0.path), $0) }, uniquingKeysWith: { first, _ in first })
        var plan = ClipboardAddPlan(
            mode: mode, added: [], switched: [], alreadyThere: [], absorbed: [], insideListed: [], clashes: [],
            entries: [:])

        let pickedKeys = Set(picked.map(ExactKey.init))
        for path in picked {
            if let pick = onClipboard[ExactKey(path)] {
                if pick.mode == mode {
                    plan.alreadyThere.append(path)
                } else {
                    plan.switched.append(path)
                }
                continue
            }
            // A folder on the clipboard holding it: it goes with that folder already.
            if let folder = deepestHolder(parentPrefix(path), { onClipboard[ExactKey($0)] != nil }),
                !pickedKeys.contains(ExactKey(folder))
            {
                plan.insideListed.append((path, folder))
                continue
            }
            plan.added.append(path)
            if let entry = entry(entries, path) { plan.entries[path] = entry }
        }

        // Items on the clipboard inside a folder now added come off, whatever their intent: they go with it.
        let addedKeys = Set(plan.added.map(ExactKey.init))
        plan.absorbed = picks.map(\.path).filter { path in
            deepestHolder(parentPrefix(path), { addedKeys.contains(ExactKey($0)) }) != nil
        }

        // Names, as one folder would hold them: what stays on the clipboard, then each item as it is added.
        let absorbedKeys = Set(plan.absorbed.map(ExactKey.init))
        var holders: [NameKeys.Exact: String] = [:]
        for pick in picks where !absorbedKeys.contains(ExactKey(pick.path)) {
            let key = sharedNameKey(pick.path)
            if holders[key] == nil { holders[key] = pick.path }
        }
        for path in plan.added {
            let key = sharedNameKey(path)
            if let other = holders[key] {
                plan.clashes.append(ClipboardNameClash(path: path, otherPath: other))
            } else {
                holders[key] = path
            }
        }
        return plan
    }

    /// The clipboard once `plan` is done, the clashes answered with `answer`. On an empty clipboard an Add is a Copy
    /// or Cut, under `stamp` as its `capturedAt`; on one with items it keeps theirs, and is then one to put back if a
    /// Copy or Cut replaces it. What it added or switched is marked at `stamp`, so those marks flash.
    public static func applyAdd(
        _ plan: ClipboardAddPlan, to clipboard: CopyPasteClipboard, answer: ClipboardClashAnswer = .keepBoth,
        stamp: String
    ) -> (clipboard: CopyPasteClipboard, report: ClipboardAddReport) {
        var report = ClipboardAddReport(
            mode: plan.mode, added: [], switched: plan.switched, alreadyThere: plan.alreadyThere,
            absorbed: plan.absorbed, insideListed: plan.insideListed, keptBoth: [], replacedOnClipboard: [],
            leftOff: [], startedClipboard: !clipboard.hasItems)
        let absorbed = Set(plan.absorbed.map(ExactKey.init))
        let switching = Set(plan.switched.map(ExactKey.init))
        var picks: [ClipboardPick] = clipboard.picks.compactMap { pick in
            if absorbed.contains(ExactKey(pick.path)) { return nil }
            var pick = pick
            if switching.contains(ExactKey(pick.path)) {
                pick.mode = plan.mode
                pick.markedAt = stamp
            }
            return pick
        }
        let clashing = Set(plan.clashes.map { ExactKey($0.path) })
        for path in plan.added {
            var pick = ClipboardPick(path: path, mode: plan.mode, entry: plan.entries[path], markedAt: stamp)
            if clashing.contains(ExactKey(path)) {
                switch answer {
                case .keepBoth:
                    pick.renamedIfShared = true
                    report.keptBoth.append(path)
                case .useThisOne:
                    let key = sharedNameKey(path)
                    let others = picks.filter { sharedNameKey($0.path) == key }
                    report.replacedOnClipboard += others.map(\.path)
                    // An item this same Add put on and now takes off was never on the clipboard to the person.
                    report.added.removeAll { added in others.contains { JSString.equals($0.path, added) } }
                    picks.removeAll { sharedNameKey($0.path) == key }
                case .dontAdd:
                    report.leftOff.append(path)
                    continue
                }
            }
            picks.append(pick)
            report.added.append(path)
        }
        report.replacedOnClipboard.removeAll { replaced in plan.added.contains { JSString.equals($0, replaced) } }
        let wasEmpty = !clipboard.hasItems
        let next: CopyPasteClipboard =
            wasEmpty
            ? .holding(picks, capturedAt: stamp, grown: false)
            : .holding(
                picks, capturedAt: clipboard.capturedAt ?? stamp, grown: clipboard.isGrown || !report.added.isEmpty)
        return (settled(next), report)
    }
}
