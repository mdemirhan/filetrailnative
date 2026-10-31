// Port of apps/desktop/src/main/settingsWindowTab.ts and SETTINGS_TABS of apps/desktop/src/renderer/SettingsWindowApp.tsx
import Foundation

/// A section of the Settings window, in the order of its sidebar (`settingsTabSchema`).
public enum SettingsTab: String, CaseIterable, Sendable, Hashable {
    case general, browsing, search, files, shortcuts

    /// The name in the sidebar and above the page.
    public var label: String {
        switch self {
        case .general: "General"
        case .browsing: "Browsing"
        case .search: "Search"
        case .files: "Files"
        case .shortcuts: "Shortcuts"
        }
    }

    /// The colours of the tile behind the section's icon, top to bottom (`.settings-sidebar-icon[data-tone]`).
    public var tone: (top: RGBA, bottom: RGBA) {
        switch self {
        case .general: (RGBA(r: 0xa3, g: 0xa3, b: 0xa9), RGBA(r: 0x80, g: 0x80, b: 0x86))
        case .browsing: (RGBA(r: 0x4a, g: 0x9b, b: 0xff), RGBA(r: 0x1f, g: 0x6f, b: 0xe8))
        case .search: (RGBA(r: 0x8f, g: 0x7b, b: 0xf5), RGBA(r: 0x67, g: 0x50, b: 0xde))
        case .files: (RGBA(r: 0xff, g: 0xab, b: 0x45), RGBA(r: 0xf3, g: 0x86, b: 0x1b))
        case .shortcuts: (RGBA(r: 0x7f, g: 0x8d, b: 0xa5), RGBA(r: 0x5d, g: 0x6a, b: 0x82))
        }
    }

    /// The icon's SVG path data, in a 24 by 24 box.
    public var iconPath: String {
        switch self {
        case .general:
            "M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6zM19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z"
        case .browsing: "M3 5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2zM9 3v18"
        case .search: "M11 17.5a6.5 6.5 0 1 0 0-13 6.5 6.5 0 0 0 0 13zM20 20l-4.2-4.2"
        case .files: "M8 3h7l5 5v11a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2zM15 3v5h5"
        case .shortcuts:
            "M5 6.5h14A2.5 2.5 0 0 1 21.5 9v6a2.5 2.5 0 0 1-2.5 2.5H5A2.5 2.5 0 0 1 2.5 15V9A2.5 2.5 0 0 1 5 6.5zM6.5 10.5h.01M10 10.5h.01M13.5 10.5h.01M17 10.5h.01M8 14h8"
        }
    }

    /// `readSettingsTabFromUrl`: the tab named after "#settings/" in a Settings window's address, or nil. The Swift
    /// window keeps its tab in memory, but the address form is kept so the tab can be named the original's way.
    public static func read(fromURL url: String) -> SettingsTab? {
        guard let hash = url.firstIndex(of: "#") else { return nil }
        let fragment = url[hash...]
        let prefix = "#settings/"
        guard fragment.hasPrefix(prefix) else { return nil }
        let name = fragment.dropFirst(prefix.count)
        guard !name.isEmpty, name.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) }) else { return nil }
        return SettingsTab(rawValue: String(name))
    }

    /// The address a window on this tab has (`#settings/<tab>`).
    public var urlFragment: String { "#settings/\(rawValue)" }
}
