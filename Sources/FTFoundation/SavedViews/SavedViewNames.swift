import Foundation

/// A saved view with a name of its own: a tab view or a window view.
public protocol NamedSavedView: Sendable {
    var id: String { get }
    var name: String { get }
}

/// The rules of the names of tab views and window views, the same for both: unique ignoring case and how an accented
/// letter is stored, up to `nameLimit` long, at most `limit` of each kind.
public enum SavedViewNames {
    /// How many of each kind are kept.
    public static let limit = 50
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

    /// What a window says when no more can be saved: "No more tab views can be saved".
    public static func limitTitle(kind: String) -> String { "No more \(kind) can be saved" }

    public static let limitMessage =
        "Up to \(limit) are kept. Remove one in the Views window (Saved Views \u{203A} Manage) to save another."

    /// A new id, with the kind's prefix.
    public static func newID(_ prefix: String) -> String {
        "\(prefix)-\(UUID().uuidString.lowercased())"
    }
}
