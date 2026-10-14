// Port of apps/desktop/src/renderer/lib/eject.ts
import Foundation

/// What Eject does with a disk: eject it at once, or first ask whether to eject the other volumes on the same
/// physical disk too (a partitioned drive), as Finder asks.
public enum EjectPlan: Sendable, Equatable {
    case eject(path: String)
    case askWhichVolumes(path: String, name: String, otherNames: [String])
}

public struct EjectNotice: Sendable, Equatable {
    public var title: String
    public var message: String
}

public enum EjectPlanning {
    public static func planEject(_ volumes: [Volume], path: String) -> EjectPlan? {
        guard let volume = volumes.first(where: { $0.path == path }), volume.canEject else { return nil }
        let others =
            volume.disk == nil
            ? [] : volumes.filter { $0.disk == volume.disk && $0.path != volume.path }
        return others.isEmpty
            ? .eject(path: path)
            : .askWhichVolumes(path: path, name: volume.name, otherNames: others.map(\.name))
    }

    public enum FocusedPane: Sendable { case tree, content }

    /// The disk Cmd-E ejects: the sidebar's selected row, when it is a disk that can be ejected (its Locations
    /// row, or the top of a tree rooted at it). With the file list in front, Cmd-E would act on its selection,
    /// which never holds a disk, so nothing is ejected. Tree item ids are "location:<path>" and "fs:<path>".
    public static func resolveEjectTargetPath(
        focusedPane: FocusedPane?, selectedTreeItemId: String?, volumes: [Volume]
    ) -> String? {
        if focusedPane == .content { return nil }
        guard let id = selectedTreeItemId else { return nil }
        let path: String
        if id.hasPrefix("location:") {
            path = String(id.dropFirst("location:".count))
        } else if id.hasPrefix("fs:") {
            path = String(id.dropFirst("fs:".count))
        } else {
            return nil
        }
        return volumes.contains { $0.path == path && $0.canEject } ? path : nil
    }

    public static func isEjectablePath(_ volumes: [Volume], path: String?) -> Bool {
        guard let path else { return false }
        return volumes.contains { $0.path == path && $0.canEject }
    }

    private static func volumeName(_ volumes: [Volume], _ path: String) -> String {
        if let volume = volumes.first(where: { $0.path == path }) { return volume.name }
        return path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? path
    }

    /// "disk" for a drive or a disk image, "volume" for a network share, as Finder words it.
    private static func noun(_ volumes: [Volume], _ path: String) -> String {
        volumes.first(where: { $0.path == path })?.isLocal == false ? "volume" : "disk"
    }

    private static let listedNames = 3

    /// `toLocaleString()` of a count.
    private static func countText(_ count: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        return formatter.string(from: NSNumber(value: count)) ?? String(count)
    }

    private static func listNames(_ names: [String]) -> String {
        let quoted = names.prefix(listedNames).map { "\u{201C}\($0)\u{201D}" }
        let unlisted = names.count - quoted.count
        if unlisted > 0 {
            return "\(quoted.joined(separator: ", ")) and \(countText(unlisted)) more"
        }
        if quoted.count <= 1 { return quoted.joined() }
        return "\(quoted.dropLast().joined(separator: ", ")) and \(quoted[quoted.count - 1])"
    }

    /// Finder's question for one volume of a disk that holds others: Eject All is the default.
    public static func describeWhichVolumesQuestion(name: String, otherNames: [String]) -> EjectNotice {
        let total = otherNames.count + 1
        return EjectNotice(
            title:
                "Do you want to eject \u{201C}\(name)\u{201D} only, or all \(countText(total)) volumes on its disk?",
            message:
                "The disk also holds \(listNames(otherNames)). Eject All lets you disconnect it; Eject leaves the others mounted."
        )
    }

    /// Finder's alert for a disk that something still has a file open on.
    public static func describeEjectBusy(_ volumes: [Volume], busyPath: String) -> EjectNotice {
        let kind = noun(volumes, busyPath)
        return EjectNotice(
            title:
                "The \(kind) \u{201C}\(volumeName(volumes, busyPath))\u{201D} wasn\u{2019}t ejected because one or more programs may be using it.",
            message:
                "To eject the \(kind) immediately, click Force Eject. A program using it may lose changes it hasn\u{2019}t saved."
        )
    }

    public static func describeEjectFailure(
        _ volumes: [Volume], path: String, failedPath: String?, code: String?, reason: String?
    ) -> EjectNotice {
        // A failure after the volumes were unmounted is the disk's own (/dev/diskN): it is named by the
        // volume asked for.
        let failedVolume = failedPath?.hasPrefix("/Volumes/") == true ? failedPath ?? path : path
        let kind = noun(volumes, failedVolume)
        let title = "The \(kind) \u{201C}\(volumeName(volumes, failedVolume))\u{201D} couldn\u{2019}t be ejected."
        if let reason, !reason.isEmpty {
            return EjectNotice(title: title, message: reason)
        }
        switch code {
        case "ETIMEDOUT":
            return EjectNotice(
                title: title, message: "The \(kind) didn\u{2019}t answer in time. Try again in a moment.")
        case "EPERM", "EACCES":
            return EjectNotice(title: title, message: "macOS didn\u{2019}t allow File Trail to eject it.")
        default:
            if let code, !code.isEmpty {
                return EjectNotice(title: title, message: "An unexpected error occurred (\(code)).")
            }
            return EjectNotice(title: title, message: "An unexpected error occurred.")
        }
    }
}
