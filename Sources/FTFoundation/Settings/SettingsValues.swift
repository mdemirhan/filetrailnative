import Foundation

extension Density {
    /// The Sizes setting's name for the density.
    public var settingsLabel: String {
        switch self {
        case .standard: "Default"
        case .finder: "Match Finder"
        }
    }
}

public enum SettingsValues {
    /// `describeKeys`: the keys a sentence names, or nothing when none of them is set, as "⌘O and ⌘↓ always open.".
    public static func describeKeys(_ labels: [String?], before: String, after: String, separator: String = ", ")
        -> String
    {
        let keys = labels.compactMap { $0 }
        return keys.isEmpty ? "" : before + keys.joined(separator: separator) + after
    }

    /// The Return key row's description: the keys of Open and Open Selected Item, which always open.
    public static func returnKeyDescription(_ display: ShortcutDisplay) -> String {
        describeKeys(
            [display.label(.openSelection), display.label(.openSelectedItem)], before: "", after: " always open.",
            separator: " and ")
    }

    /// The item limit field when it is left or Return is pressed: what is not whole digits is the default
    /// 5; a number is brought into 1 to 50. The field shows the result; the value is nil when nothing changes.
    public static func commitOpenItemLimit(_ draft: String, current: Int) -> (text: String, value: Int?) {
        let trimmed = JSString.trimmed(draft)
        let digits = !trimmed.isEmpty && trimmed.unicodeScalars.allSatisfy { ("0"..."9").contains($0) }
        let next =
            digits
            ? AppPreferenceLimits.clampOpenItemLimit(Double(trimmed) ?? Double(AppPreferenceLimits.openItemLimitMax))
            : AppPreferences.defaults().openItemLimit
        return (String(next), next == current ? nil : next)
    }

    /// An item of a list moved to another place in it; out of range changes nothing.
    public static func move<T>(_ items: [T], from index: Int, to target: Int) -> [T] {
        guard items.indices.contains(index), items.indices.contains(target) else { return items }
        var next = items
        let item = next.remove(at: index)
        next.insert(item, at: target)
        return next
    }

    /// An id no other pinned app has.
    public static func openWithApplicationID(now: Date = Date(), random: UInt32 = .random(in: 0...UInt32.max))
        -> String
    {
        let time = String(UInt64(now.timeIntervalSince1970 * 1000), radix: 36)
        let suffix = String(String(random, radix: 36).prefix(6))
        return "open-with-\(time)-\(suffix)"
    }

    /// Restore Defaults under Appearance: the theme and the accent go back (the zoom is not drawn).
    public static func resetAppearance(_ preferences: inout AppPreferences) {
        let defaults = AppPreferences.defaults()
        preferences.theme = defaults.theme
        preferences.accent = defaults.accent
    }
}

/// The texts of the Settings window that are not labels of a control.
public enum SettingsText {
    public static let loadFailed = "Couldn’t load the settings."
    public static let chooseFolderFailed = "Couldn’t choose a folder."
    public static let chooseAppFailed = "Couldn’t choose an app."
    public static let chooseTerminalFailed = "Couldn’t choose the terminal app."
    public static let chooseTextEditorFailed = "Couldn’t choose the text editor."
    public static let missingApp = "Not found · "

    /// A folder chosen for Add or Change… that is a favorite already.
    public static func alreadyFavorite(_ name: String) -> String { "\u{201C}\(name)\u{201D} is already a favorite." }
}
