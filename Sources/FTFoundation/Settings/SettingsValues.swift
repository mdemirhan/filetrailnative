// Port of the logic of apps/desktop/src/renderer/components/SettingsView.tsx (describeKeys, resolveDensity,
// OpenItemLimitInput, moveItem) and the notices and payload of apps/desktop/src/renderer/SettingsWindowApp.tsx
import Foundation

/// Density for every view at once: the four switches it sets were once separate, and a profile that still has them
/// mixed shows as Custom until a density is chosen (B-DLG-181, F-072).
public enum SettingsDensity: String, CaseIterable, Sendable {
    case comfortable, compact, custom

    /// `resolveDensity`.
    public static func resolve(_ flags: [Bool]) -> SettingsDensity {
        if flags.allSatisfy({ $0 }) { return .compact }
        return flags.contains(true) ? .custom : .comfortable
    }

    /// The density of the four flags of `preferences`.
    public static func of(_ preferences: AppPreferences) -> SettingsDensity {
        resolve([
            preferences.compactListView, preferences.compactDetailsView, preferences.compactIconView,
            preferences.compactTreeView,
        ])
    }

    /// The choices the pop-up lists: Custom only while it is the density, and never choosable.
    public static func options(for density: SettingsDensity) -> [SettingsDensity] {
        density == .custom ? [.comfortable, .compact, .custom] : [.comfortable, .compact]
    }

    public var label: String {
        switch self {
        case .comfortable: "Comfortable"
        case .compact: "Compact"
        case .custom: "Custom"
        }
    }

    /// `setDensity`: Comfortable or Compact sets all four flags; Custom changes nothing.
    public func apply(to preferences: inout AppPreferences) {
        guard self != .custom else { return }
        let compact = self == .compact
        preferences.compactListView = compact
        preferences.compactDetailsView = compact
        preferences.compactIconView = compact
        preferences.compactTreeView = compact
    }
}

public enum SettingsValues {
    /// The keys the Settings window shows and writes (the window's `payload`).
    public static let payloadKeys: [String] = [
        "theme", "accent", "zoomPercent", "compactListView", "compactDetailsView", "compactIconView",
        "compactTreeView", "singleClickExpandTreeItems", "detailColumns", "detailColumnOrder", "searchColumns",
        "searchColumnOrder", "notificationsEnabled", "markClipboardItems", "autoCalculateFolderSizes",
        "restoreSessionOnStartup", "favorites", "favoritesPlacement", "terminalApp", "defaultTextEditor",
        "openWithApplications", "fileActivationAction", "diskImageOpensIn", "returnKeyAction", "shortcutOverrides",
        "openItemLimit", "searchPatternMode", "searchMatchScope", "searchRecursive", "searchSkipGitFolders",
        "searchSkipGitIgnored",
    ]

    /// The payload of `preferences`: the keys Settings writes, as JSON.
    public static func payload(_ preferences: AppPreferences) -> PreferencesPatch {
        let all = (try? JSONNode.of(preferences).object) ?? [:]
        return all.filter { payloadKeys.contains($0.key) }
    }

    /// `preferences` with the values of `patch` (`applyPreferencesPatch`); keys it doesn't know are left out.
    public static func applying(_ patch: PreferencesPatch, to preferences: AppPreferences) -> AppPreferences {
        guard !patch.isEmpty, var all = (try? JSONNode.of(preferences).object) else { return preferences }
        all.merge(patch) { _, new in new }
        return (try? JSONNode.object(all).decode(AppPreferences.self)) ?? preferences
    }

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

    /// The item limit field when it is left or Return is pressed (B-DLG-191): what is not whole digits is the default
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

    /// `moveItem`: an item of a list moved to another place in it; out of range changes nothing.
    public static func move<T>(_ items: [T], from index: Int, to target: Int) -> [T] {
        guard items.indices.contains(index), items.indices.contains(target) else { return items }
        var next = items
        let item = next.remove(at: index)
        next.insert(item, at: target)
        return next
    }

    /// `createOpenWithApplicationId`: an id no other pinned app has.
    public static func openWithApplicationID(now: Date = Date(), random: UInt32 = .random(in: 0...UInt32.max))
        -> String
    {
        let time = String(UInt64(now.timeIntervalSince1970 * 1000), radix: 36)
        let suffix = String(String(random, radix: 36).prefix(6))
        return "open-with-\(time)-\(suffix)"
    }

    /// Restore Defaults under Appearance: the theme and the accent go back (the zoom is not drawn, D-005).
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
}
