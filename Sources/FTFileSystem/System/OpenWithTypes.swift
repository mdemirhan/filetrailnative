// Port of the answer shapes of packages/native-fs/src/native_openwith.m and system:getOpenWithApplications
import Foundation

/// An app as Open With knows it.
public struct ApplicationInfo: Equatable, Sendable, Codable {
    public var path: String
    public var name: String
    public var bundleId: String?
    public var version: String?

    public init(path: String, name: String, bundleId: String? = nil, version: String? = nil) {
        self.path = path
        self.name = name
        self.bundleId = bundleId
        self.version = version
    }
}

/// The kind of an item: its type and what Finder's Kind column says.
public struct OpenWithKind: Equatable, Sendable, Codable {
    public var contentType: String
    public var name: String?
    public var isFolder: Bool

    public init(contentType: String, name: String?, isFolder: Bool) {
        self.contentType = contentType
        self.name = name
        self.isFolder = isFolder
    }
}

/// What Launch Services says about the items (`nativeOpenWithApplications`).
public struct LaunchServicesAnswer: Equatable, Sendable {
    public var defaultApp: ApplicationInfo?
    public var apps: [ApplicationInfo]
    public var kinds: [OpenWithKind]
    public var appInfo: [ApplicationInfo?]

    public init(
        defaultApp: ApplicationInfo? = nil, apps: [ApplicationInfo] = [], kinds: [OpenWithKind] = [],
        appInfo: [ApplicationInfo?] = []
    ) {
        self.defaultApp = defaultApp
        self.apps = apps
        self.kinds = kinds
        self.appInfo = appInfo
    }
}

/// What the Open With menu is built from (`system:getOpenWithApplications`).
public struct OpenWithLookup: Equatable, Sendable {
    public var defaultApp: ApplicationInfo?
    public var apps: [ApplicationInfo]
    public var kinds: [OpenWithKind]
    public var pinnedApps: [ApplicationInfo?]

    public init(
        defaultApp: ApplicationInfo? = nil, apps: [ApplicationInfo] = [], kinds: [OpenWithKind] = [],
        pinnedApps: [ApplicationInfo?] = []
    ) {
        self.defaultApp = defaultApp
        self.apps = apps
        self.kinds = kinds
        self.pinnedApps = pinnedApps
    }
}

/// `{ ok, error }` of the open and default-app requests.
public struct OperationResult: Equatable, Sendable {
    public var ok: Bool
    public var error: String?

    public static let success = OperationResult(ok: true, error: nil)

    public static func failure(_ message: String) -> OperationResult {
        OperationResult(ok: false, error: message)
    }
}

/// `toErrorMessage`: the error's own message.
func errorMessage(_ error: any Error) -> String {
    if let error = error as? LocalizedError, let description = error.errorDescription { return description }
    return (error as NSError).localizedDescription
}
