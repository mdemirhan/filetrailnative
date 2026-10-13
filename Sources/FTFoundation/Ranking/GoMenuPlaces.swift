// Port of apps/desktop/src/renderer/lib/goMenuPlaces.ts
import Foundation

/// The places the Go menu goes to, as Finder's does. Macintosh HD and the Trash are rows of the
/// sidebar's Locations and open as a click on the row does; the folders open as Go to Folder opens them.
public struct GoMenuPlace: Equatable, Sendable {
    public var path: String
    public var asLocation: Bool

    public init(path: String, asLocation: Bool) {
        self.path = path
        self.asLocation = asLocation
    }
}

/// The Go menu's commands that go to a place (their names are the commands' ids).
public enum GoMenuPlaceCommand: String, CaseIterable, Sendable {
    case goDocuments
    case goDesktop
    case goDownloads
    case goLibrary
    case goMacintoshHD
    case goApplications
    case goTrash

    private var homeFolder: String? {
        switch self {
        case .goDocuments: "Documents"
        case .goDesktop: "Desktop"
        case .goDownloads: "Downloads"
        case .goLibrary: "Library"
        case .goMacintoshHD, .goApplications, .goTrash: nil
        }
    }

    /// Whether the command with this id goes to a place.
    public static func isPlaceCommand(_ command: String) -> Bool {
        GoMenuPlaceCommand(rawValue: command) != nil
    }

    /// Nil until the home folder is known, for the places in it.
    public func place(homePath: String) -> GoMenuPlace? {
        switch self {
        case .goMacintoshHD:
            return GoMenuPlace(path: "/", asLocation: true)
        case .goApplications:
            return GoMenuPlace(path: "/Applications", asLocation: false)
        default:
            break
        }
        if homePath.isEmpty {
            return nil
        }
        if self == .goTrash {
            return GoMenuPlace(path: FavoriteLabel.trashPath(homePath: homePath), asLocation: true)
        }
        return GoMenuPlace(path: "\(homePath)/\(homeFolder ?? "")", asLocation: false)
    }
}
