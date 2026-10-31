// Port of apps/desktop/src/renderer/lib/openWith.ts
import FTFoundation
import Foundation

/// What a row of the Open With submenu does when chosen.
public enum OpenWithAction: Equatable, Sendable {
    case application(id: String, label: String, appPath: String, appName: String, always: Bool)
    case other(id: String, label: String, appName: String, always: Bool)

    public var label: String {
        switch self {
        case .application(_, let label, _, _, _), .other(_, let label, _, _): label
        }
    }
}

public enum OpenWithMenuItem: Equatable, Sendable {
    case separator(key: String)
    case action(OpenWithAction)
}

public enum OpenWithMenu {
    public struct Sections: Equatable, Sendable {
        public var defaultApp: ApplicationInfo?
        public var pinned: [ApplicationInfo]
        public var others: [ApplicationInfo]
    }

    /// The same app however its path was written.
    static func appKey(_ path: String) -> String {
        guard path.count > 1 else { return path }
        var key = path
        while key.hasSuffix("/") { key.removeLast() }
        return key
    }

    /// Always Open With changes what every file of one kind opens in: it is offered only when the items are all of
    /// one kind, and never for folders, packages or apps.
    public static func canAlwaysOpenWith(_ lookup: OpenWithLookup?) -> Bool {
        let kinds = lookup?.kinds ?? []
        return kinds.count == 1 && kinds[0].isFolder == false
    }

    /// An app as Open With tells apps apart: two copies of one version are one app; another version is another.
    private static func identity(_ app: ApplicationInfo) -> String {
        if let bundleId = app.bundleId, !bundleId.isEmpty { return "id:\(bundleId)\n\(app.version ?? "")" }
        return "path:\(appKey(app.path))"
    }

    /// The apps Open With lists, in order, as Finder's menu does: the default app, then the pinned apps that can
    /// open the items, then every other app macOS offers, A to Z. An app is listed once, in its first place.
    /// Until macOS has answered (`lookup` nil) only the pinned apps are known, and they are all listed.
    public static func sections(lookup: OpenWithLookup?, pinned: [OpenWithApplication]) -> Sections {
        var listed = Set<String>()
        func take(_ app: ApplicationInfo?) -> Bool {
            guard let app else { return false }
            let keys = ["path:\(appKey(app.path))", identity(app)]
            if keys.contains(where: listed.contains) { return false }
            listed.formUnion(keys)
            return true
        }
        let defaultApp = lookup?.defaultApp
        _ = take(defaultApp)
        // The answer is for the pinned list it was asked with; one asked before the list changed says nothing
        // about it.
        let pinnedInfo: [ApplicationInfo?]
        if let lookup, lookup.pinnedApps.count == pinned.count {
            pinnedInfo = lookup.pinnedApps
        } else {
            pinnedInfo = pinned.map {
                ApplicationInfo(path: $0.appPath, name: $0.appName, bundleId: nil, version: nil)
            }
        }
        // A pinned app is listed only for items macOS says it can open: by its path, or by its bundle id when
        // macOS offers another copy of it. An answer with no kinds is one macOS couldn't give.
        let offered = lookup?.apps ?? []
        func canOpen(_ app: ApplicationInfo) -> Bool {
            guard let lookup, !lookup.kinds.isEmpty else { return true }
            return offered.contains { candidate in
                appKey(candidate.path) == appKey(app.path)
                    || (app.bundleId != nil && candidate.bundleId == app.bundleId)
            }
        }
        let pinnedApps = pinnedInfo.compactMap { $0 }.filter { canOpen($0) && take($0) }
        let others = offered.filter { take($0) }.sorted { compareNames($0.name, $1.name) == .orderedAscending }
        return Sections(defaultApp: defaultApp, pinned: pinnedApps, others: others)
    }

    /// `Intl.Collator(undefined, { sensitivity: "base", numeric: true })`. `sorted` is stable, as `Array.sort`.
    static func compareNames(_ left: String, _ right: String) -> ComparisonResult {
        left.compare(
            right, options: [.caseInsensitive, .diacriticInsensitive, .numeric], range: nil, locale: Locale.current)
    }

    /// The Open With submenu. With `always` (Option held, items of one kind) choosing an app makes it the one the
    /// kind opens in, as Finder's Always Open With does.
    public static func menuItems(
        lookup: OpenWithLookup?, pinned: [OpenWithApplication], always: Bool = false
    ) -> [OpenWithMenuItem] {
        let sections = sections(lookup: lookup, pinned: pinned)
        let labels = applicationLabels(
            (sections.defaultApp.map { [$0] } ?? []) + sections.pinned + sections.others)
        var items: [OpenWithMenuItem] = []
        func addSection(_ key: String, _ apps: [ApplicationInfo], isDefault: Bool) {
            guard !apps.isEmpty else { return }
            if !items.isEmpty { items.append(.separator(key: "separator-\(key)")) }
            for app in apps {
                let label = labels[appKey(app.path)] ?? app.name
                items.append(
                    .action(
                        .application(
                            id: "app:\(appKey(app.path))", label: isDefault ? "\(label) (default)" : label,
                            appPath: app.path, appName: app.name, always: always)))
            }
        }
        addSection("default", sections.defaultApp.map { [$0] } ?? [], isDefault: true)
        addSection("pinned", sections.pinned, isDefault: false)
        addSection("others", sections.others, isDefault: false)
        if !items.isEmpty { items.append(.separator(key: "separator-other")) }
        items.append(.action(.other(id: "other", label: "Other…", appName: "Other…", always: always)))
        return items
    }

    /// Each app's name, with its version after it when another app listed has the same name (Xcode and a beta of
    /// Xcode), as Finder shows them.
    private static func applicationLabels(_ apps: [ApplicationInfo]) -> [String: String] {
        var counts: [String: Int] = [:]
        for app in apps { counts[app.name.lowercased(), default: 0] += 1 }
        var labels: [String: String] = [:]
        for app in apps {
            let shared = (counts[app.name.lowercased()] ?? 0) > 1
            if shared, let version = app.version, !version.isEmpty {
                labels[appKey(app.path)] = "\(app.name) (\(version))"
            } else {
                labels[appKey(app.path)] = app.name
            }
        }
        return labels
    }
}
