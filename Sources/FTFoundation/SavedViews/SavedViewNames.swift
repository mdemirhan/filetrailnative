import Foundation

/// A saved view with a name of its own: a tab view or a window view.
public protocol NamedSavedView: Sendable {
    var id: String { get set }
    var name: String { get set }
}

/// The rules of the names of tab views and window views, the same for both: unique ignoring case and how an accented
/// letter is stored, up to `nameLimit` long, at most `limit` of each kind.
public enum SavedViewNames {
    /// How many of each kind are kept.
    public static let limit = 20
    /// How long a name can be, in UTF-16 units.
    public static let nameLimit = 80

    /// A name as it is kept: trimmed, each accented letter composed (a folder's name on disk, which Save offers, may
    /// keep a letter and its accent apart), and cut at `nameLimit`.
    public static func clean(_ typed: String) -> String {
        BatchRenameTextRules.limited(JSString.trimmed(typed).precomposedStringWithCanonicalMapping, to: nameLimit)
    }

    /// The one with this name, ignoring case and how an accented letter is stored.
    public static func index<View: NamedSavedView>(named name: String, in views: [View]) -> Int? {
        let key = NameFolding.folded(clean(name))
        return views.firstIndex { NameFolding.folded($0.name).utf16.elementsEqual(key.utf16) }
    }

    /// The one with this id.
    public static func index<View: NamedSavedView>(id: String, in views: [View]) -> Int? {
        views.firstIndex { $0.id.utf16.elementsEqual(id.utf16) }
    }

    /// Why `name` can't be the new name of the one with `id`: another has it. Nil when it can. `kind` is "tab view"
    /// or "window view".
    public static func renameRefusal<View: NamedSavedView>(
        _ name: String, id: String, in views: [View], kind: String
    ) -> String? {
        guard let taken = index(named: name, in: views), !views[taken].id.utf16.elementsEqual(id.utf16) else {
            return nil
        }
        return "There\u{2019}s already a \(kind) called \u{201C}\(views[taken].name)\u{201D}."
    }

    /// `views` with `saved` in place of the one with its name, or at the end when none has it; past `limit` nothing is
    /// added.
    public static func saving<View: NamedSavedView>(_ saved: View, in views: [View]) -> [View] {
        var result = views
        if let existing = index(named: saved.name, in: result) {
            result[existing] = saved
        } else if result.count < limit {
            result.append(saved)
        }
        return result
    }

    /// The name of a copy of `name`: "Name copy", then "Name copy 2" and on, the first no other has. A long name is cut
    /// before its suffix, so the suffix always shows and two copies never get one name.
    public static func copyName<View: NamedSavedView>(of name: String, in views: [View]) -> String {
        let base = clean(name)
        func named(_ suffix: String) -> String {
            let room = max(0, nameLimit - suffix.utf16.count)
            return BatchRenameTextRules.limited(base, to: room) + suffix
        }
        var candidate = named(" copy")
        var number = 2
        while index(named: candidate, in: views) != nil {
            candidate = named(" copy \(number)")
            number += 1
        }
        return candidate
    }

    /// The title of the notice when no more can be kept: "Too Many Tab Views". `kind` is "tab views" or "window
    /// views".
    public static func limitTitle(kind: String) -> String {
        let words = kind.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return "Too Many " + words.joined(separator: " ")
    }

    /// The notice when a new one named `name` can't be saved, `count` being kept: what the limit is, and the two ways
    /// on, removing one or saving over one.
    public static func saveLimitMessage(kind: String, name: String, count: Int) -> String {
        "File Trail keeps up to \(FormatLocale.count(limit)) \(kind), and you have \(FormatLocale.count(count)). "
            + "To save \u{201C}\(name)\u{201D}, remove one you no longer use, or save over one by choosing its name "
            + "from the list."
    }

    /// The notice when `copies` copies can't be made, `count` being kept: what the limit is, how many more fit when
    /// some do, and the ways on.
    public static func duplicateLimitMessage(kind: String, count: Int, copies: Int) -> String {
        let room = max(0, limit - count)
        let keeps = "File Trail keeps up to \(FormatLocale.count(limit)) \(kind)"
        guard copies > 1, room > 0 else {
            let them =
                copies > 1
                ? "some you no longer use to make room for the copies"
                : "one you no longer use to make room for the copy"
            return "\(keeps), and you have \(FormatLocale.count(count)). Remove \(them)."
        }
        let fit = room == 1 ? "1 more copy fits" : "\(FormatLocale.count(room)) more copies fit"
        return "\(keeps). You have \(FormatLocale.count(count)), so \(fit), and \(FormatLocale.count(copies)) are "
            + "selected. Remove some you no longer use, or select fewer."
    }

    /// `views` with a copy of each of the ones with `ids` right after it, each copy's name the first "… copy" no other
    /// has, and the copies' ids. Nothing is copied when the copies would take the list past `limit`.
    public static func duplicating<View: NamedSavedView>(
        _ ids: [String], in views: [View], newID: () -> String
    ) -> (views: [View], copies: [String]) {
        let chosen = views.filter { view in ids.contains { $0.utf16.elementsEqual(view.id.utf16) } }
        guard !chosen.isEmpty, views.count + chosen.count <= limit else { return (views, []) }
        var result = views
        var copies: [String] = []
        for original in chosen {
            guard let at = index(id: original.id, in: result) else { continue }
            var copy = original
            copy.id = newID()
            copy.name = copyName(of: original.name, in: result)
            result.insert(copy, at: at + 1)
            copies.append(copy.id)
        }
        return (result, copies)
    }

    /// `views` with the ones at `rows` taken out and put, in their order, before the one at `target` (the end at
    /// `views.count`); where the first of them landed. Out of range changes nothing.
    public static func moving<View>(_ views: [View], rows: IndexSet, to target: Int) -> (views: [View], at: Int) {
        guard !rows.isEmpty, rows.allSatisfy(views.indices.contains), target >= 0, target <= views.count else {
            return (views, rows.first ?? 0)
        }
        let moved = rows.map { views[$0] }
        var rest = views.enumerated().filter { !rows.contains($0.offset) }.map(\.element)
        let at = target - rows.count(in: 0..<target)
        rest.insert(contentsOf: moved, at: at)
        return (rest, at)
    }

    /// A new id, with the kind's prefix.
    public static func newID(_ prefix: String) -> String {
        "\(prefix)-\(UUID().uuidString.lowercased())"
    }
}
