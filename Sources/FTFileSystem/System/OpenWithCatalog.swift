// Port of packages/native-fs/src/native_openwith.m
import AppKit
import CoreServices
import Foundation
import UniformTypeIdentifiers

/// The apps Launch Services knows can open a file, and the app each file opens in.
///
/// Remembered between calls, until `forget()` (or a default app is changed here): for each type, the apps that can
/// open it and its kind name; for each app path, its name, version and bundle id (or that there is no app there).
/// Asked every time: each file's type, and the app it opens in, which Finder's Get Info can set for one file alone.
public final class OpenWithCatalog: @unchecked Sendable {
    /// Past this many entries a cache starts again empty rather than growing.
    static let cacheMax = 1024
    /// How long setting a default app may take before it is given up on.
    static let setDefaultTimeout: Duration = .seconds(10)

    private struct TypeEntry {
        var kind: OpenWithKind
        var apps: [URL]
    }

    private let lock = NSLock()
    private var typeCache: [String: TypeEntry] = [:]
    private var appCache: [String: ApplicationInfo?] = [:]

    public static let shared = OpenWithCatalog()

    public init() {}

    /// Drops what is remembered, as when apps may have been installed or removed.
    public func forget() {
        lock.lock()
        typeCache.removeAll()
        appCache.removeAll()
        lock.unlock()
    }

    // MARK: Lookup

    /// `nativeOpenWithApplications`. Launch Services can be slow on a cold start: call off the main thread.
    public func lookup(paths: [String], appPaths: [String]) -> LaunchServicesAnswer {
        let workspace = NSWorkspace.shared
        var kinds: [OpenWithKind] = []
        var seenTypes = Set<String>()
        // The apps that can open every path so far, by key, in Launch Services' order.
        var commonKeys: [String]?
        var urlsByKey: [String: URL] = [:]
        var defaultKey: String?
        var defaultsAgree = true

        for path in paths where !path.isEmpty {
            let url = URL(fileURLWithPath: path)

            // Each file can have its own default (Finder's Get Info sets one), so it is asked for each, until
            // two differ.
            if defaultsAgree {
                let defaultURL = workspace.urlForApplication(toOpen: url)
                let key = defaultURL.map(Self.appKey)
                if let key, let defaultURL, defaultKey == nil || defaultKey == key {
                    defaultKey = key
                    urlsByKey[key] = defaultURL
                } else {
                    defaultsAgree = false
                    defaultKey = nil
                }
            }

            // The apps that can open a file depend only on its type: asked once per type.
            let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
            let typeId = type?.identifier ?? "path:" + path
            guard seenTypes.insert(typeId).inserted else { continue }
            let appURLs: [URL]
            if let type {
                let entry = typeEntry(workspace, url: url, path: path, type: type)
                kinds.append(entry.kind)
                appURLs = entry.apps
            } else {
                // A file macOS gives no type is asked about alone, and not remembered.
                appURLs = workspace.urlsForApplications(toOpen: url)
            }
            var keys: [String] = []
            for appURL in appURLs {
                let key = Self.appKey(appURL)
                if !keys.contains(key) {
                    keys.append(key)
                    urlsByKey[key] = appURL
                }
            }
            if let current = commonKeys {
                let keySet = Set(keys)
                commonKeys = current.filter { keySet.contains($0) }
            } else {
                commonKeys = keys
            }
        }

        let apps = (commonKeys ?? []).compactMap { key in urlsByKey[key].flatMap(cachedAppInfo) }
        let defaultApp = defaultKey.flatMap { urlsByKey[$0] }.flatMap(cachedAppInfo)
        let appInfo = appPaths.map { path in
            path.isEmpty ? nil : cachedAppInfo(URL(fileURLWithPath: path))
        }
        return LaunchServicesAnswer(defaultApp: defaultApp, apps: apps, kinds: kinds, appInfo: appInfo)
    }

    /// An app's path without a trailing slash, so the same app always has the same key.
    static func appKey(_ url: URL) -> String {
        var path = url.standardizedFileURL.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// The name Finder shows for an app, its version and bundle id; nil when there is no app.
    static func appInfo(at url: URL) -> ApplicationInfo? {
        guard let isDirectory = try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory, isDirectory else {
            return nil
        }
        let bundle = Bundle(url: url)
        var name = (try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName) ?? ""
        if name.isEmpty { name = url.lastPathComponent }
        if name.lowercased().hasSuffix(".app") && name.count > 4 { name = String(name.dropLast(4)) }
        let version = bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let bundleId = bundle?.bundleIdentifier
        return ApplicationInfo(
            path: appKey(url), name: name, bundleId: bundleId.flatMap { $0.isEmpty ? nil : $0 },
            version: version.flatMap { $0.isEmpty ? nil : $0 })
    }

    /// What Finder's Kind column says for the file ("Markdown Document", "Plain Text Document"): Spotlight's kind,
    /// else the type's own description ("Markdown", "text").
    static func kindName(path: String, type: UTType) -> String? {
        if let item = MDItemCreate(kCFAllocatorDefault, path as CFString),
            let kind = MDItemCopyAttribute(item, kMDItemKind) as? String, !kind.isEmpty
        {
            return kind
        }
        let description = type.localizedDescription ?? ""
        return description.isEmpty ? nil : description
    }

    private func cachedAppInfo(_ url: URL) -> ApplicationInfo? {
        let key = Self.appKey(url)
        lock.lock()
        let cached = appCache[key]
        lock.unlock()
        if let cached { return cached }
        let info = Self.appInfo(at: url)
        lock.lock()
        if appCache.count >= Self.cacheMax { appCache.removeAll() }
        appCache[key] = .some(info)
        lock.unlock()
        return info
    }

    /// The kind of a type and the apps that can open it, in Launch Services' order, worked out from one file of
    /// the type and remembered by the type.
    private func typeEntry(_ workspace: NSWorkspace, url: URL, path: String, type: UTType) -> TypeEntry {
        lock.lock()
        let cached = typeCache[type.identifier]
        lock.unlock()
        if let cached { return cached }
        var apps: [URL] = []
        var seen = Set<String>()
        for appURL in workspace.urlsForApplications(toOpen: url) where seen.insert(Self.appKey(appURL)).inserted {
            apps.append(appURL)
        }
        let entry = TypeEntry(
            kind: OpenWithKind(
                contentType: type.identifier, name: Self.kindName(path: path, type: type),
                isFolder: type.conforms(to: .directory)),
            apps: apps)
        lock.lock()
        if typeCache.count >= Self.cacheMax { typeCache.removeAll() }
        typeCache[type.identifier] = entry
        lock.unlock()
        return entry
    }

    // MARK: Always Open With

    public struct SetDefaultFailure: Error, LocalizedError, Equatable {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// `nativeSetDefaultApplication`: makes the app the one every file of the type opens in. Refused for folders,
    /// packages and apps.
    public func setDefaultApplication(appPath: String, contentType: String) async throws {
        guard !contentType.isEmpty, let type = UTType(contentType) else {
            throw SetDefaultFailure(message: "That kind of file isn't known to macOS.")
        }
        // Folders, packages and apps are left as they are: changing what opens every folder would take them all
        // away from Finder.
        if type.conforms(to: .directory) {
            throw SetDefaultFailure(message: "Folders, apps and packages keep the app they open in.")
        }
        defer {
            // What the type opens in has changed, or may have: what is remembered is asked again.
            forget()
        }
        let appURL = URL(fileURLWithPath: appPath)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                do {
                    try await NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: type)
                } catch {
                    let message = (error as NSError).localizedDescription
                    throw SetDefaultFailure(message: message.isEmpty ? "macOS refused the change." : message)
                }
            }
            group.addTask {
                try await Task.sleep(for: Self.setDefaultTimeout)
                throw SetDefaultFailure(message: "macOS didn't answer.")
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }
}
