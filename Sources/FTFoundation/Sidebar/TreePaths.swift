// Port of the tree-root cases of apps/desktop/src/renderer/lib/explorerAppUtils.ts and the tree helpers of lib/explorerNavigation.ts
import Foundation

/// Which folders the sidebar's tree holds, where it is rooted, and which hidden folders and packages stay on the way
/// to the folder on screen.
public enum TreePaths {
    /// Two paths are the same when their code units are (`===` of strings): the NFC and NFD spellings of a name differ.
    public static func same(_ first: String, _ second: String) -> Bool {
        JSString.equals(first, second)
    }

    // MARK: Tree root

    /// `isPathWithinRoot`.
    public static func isWithinRoot(_ path: String, _ rootPath: String) -> Bool {
        if JSString.equals(rootPath, "/") { return true }
        return JSString.equals(path, rootPath) || path.utf8.starts(with: (rootPath + "/").utf8)
    }

    /// `getVolumeRootPath`: `/Volumes/<name>` for a path on another disk, otherwise `/`.
    public static func volumeRootPath(_ path: String) -> String {
        let prefix = "/Volumes/"
        guard path.hasPrefix(prefix) else { return "/" }
        let name = path.dropFirst(prefix.count).prefix { $0 != "/" }
        return name.isEmpty ? "/" : prefix + name
    }

    /// `isPathWithinTreeRoot`: whether the folder tree rooted at `rootPath` holds `path`. Rooted at Macintosh HD it
    /// holds the startup disk's own folders only: another disk, though mounted inside it at /Volumes, is shown from
    /// its own top.
    public static func isWithinTreeRoot(_ path: String, _ rootPath: String) -> Bool {
        if JSString.equals(rootPath, "/") {
            return JSString.equals(volumeRootPath(path), "/")
        }
        return isWithinRoot(path, rootPath)
    }

    /// `resolveExplorerTreeRootPath`: the top the tree takes for `path` when it is not rooted somewhere holding it:
    /// Home for what is in Home, the disk for what is on another disk, otherwise Macintosh HD.
    public static func resolveRootPath(for path: String, homePath: String) -> String {
        if !homePath.isEmpty, isWithinRoot(path, homePath) { return homePath }
        return volumeRootPath(path)
    }

    // MARK: Paths in the tree

    /// `parentDirectoryPath`: nil above `/`.
    public static func parent(of path: String) -> String? {
        if JSString.equals(path, "/") { return nil }
        let parts = JSString.components(path, separator: 0x2F)
        if parts.count <= 1 { return "/" }
        return "/" + parts.dropLast().joined(separator: "/")
    }

    /// `getAncestorChain`: from the tree's root down to `path`; just the root when `path` is outside it.
    public static func ancestorChain(from rootPath: String, to path: String) -> [String] {
        if !isWithinRoot(path, rootPath) || JSString.equals(rootPath, path) { return [rootPath] }
        var ancestors: [String] = []
        var current: String? = path
        while let candidate = current, !candidate.isEmpty, !JSString.equals(candidate, rootPath) {
            ancestors.append(candidate)
            current = parent(of: candidate)
        }
        ancestors.append(rootPath)
        return ancestors.reversed()
    }

    /// `getTreeSeedChain`: each ancestor and the child to open under it.
    public static func seedChain(from rootPath: String, to focusPath: String) -> [(path: String, childPath: String?)] {
        let chain = ancestorChain(from: rootPath, to: focusPath)
        return chain.enumerated().map { index, path in
            (path, index + 1 < chain.count ? chain[index + 1] : nil)
        }
    }

    /// `pathSegmentName`.
    static func segmentName(_ path: String) -> String {
        if JSString.equals(path, "/") { return "/" }
        return JSString.components(path, separator: 0x2F).last ?? path
    }

    /// `pathHasHiddenSegmentWithinRoot`: hidden files can be off while the selection lives under a hidden folder.
    public static func hasHiddenSegment(_ path: String, withinRoot rootPath: String) -> Bool {
        guard isWithinRoot(path, rootPath) else { return false }
        if JSString.equals(rootPath, path) { return segmentName(path).hasPrefix(".") }
        let relative = JSString.equals(rootPath, "/") ? String(path.dropFirst()) : String(path.dropFirst(rootPath.count + 1))
        return JSString.components(relative, separator: 0x2F).contains { $0.hasPrefix(".") }
    }

    /// `getChildPathTowards`: the child of `parentPath` that `activePath` is, or is inside.
    static func childPath(of parentPath: String, towards activePath: String) -> String? {
        guard isWithinRoot(activePath, parentPath), !JSString.equals(activePath, parentPath) else { return nil }
        let relative =
            JSString.equals(parentPath, "/") ? String(activePath.dropFirst()) : String(activePath.dropFirst(parentPath.count + 1))
        guard let next = JSString.components(relative, separator: 0x2F).first else { return nil }
        return JSString.equals(parentPath, "/") ? "/\(next)" : "\(parentPath)/\(next)"
    }

    /// `getForcedVisibleHiddenChildPath`: the one hidden child of `parentPath` that stays listed so the folder on
    /// screen does not disappear from the tree while hidden files are off.
    public static func forcedVisibleHiddenChild(of parentPath: String, activePath: String) -> String? {
        guard let child = childPath(of: parentPath, towards: activePath), segmentName(child).hasPrefix(".") else {
            return nil
        }
        return child
    }

    /// `getForcedVisiblePackageChildPath`: the tree lists no packages, so one that is open, or that the open folder is
    /// inside (Show Package Contents), is added under `parentPath` to keep the path to it in the tree.
    public static func forcedVisiblePackageChild(of parentPath: String, activePath: String) -> String? {
        guard let child = childPath(of: parentPath, towards: activePath),
            ItemNames.isMacOSPackageName(segmentName(child))
        else { return nil }
        return child
    }

    /// One row of a folder read for the tree.
    public struct Child: Equatable, Sendable {
        public var path: String
        public var name: String
        public var isHidden: Bool
        public var isSymlink: Bool

        public init(path: String, name: String, isHidden: Bool, isSymlink: Bool) {
            self.path = path
            self.name = name
            self.isHidden = isHidden
            self.isSymlink = isSymlink
        }
    }

    /// `withPackageChild`: `children` with the package at `packagePath` among them, in the order the tree lists names.
    public static func withPackageChild(_ children: [Child], packagePath: String) -> [Child] {
        if children.contains(where: { JSString.equals($0.path, packagePath) }) { return children }
        let name = segmentName(packagePath)
        let package = Child(path: packagePath, name: name, isHidden: name.hasPrefix("."), isSymlink: false)
        let index = children.firstIndex { naturalCompare($0.name, name) == .orderedDescending }
        guard let index else { return children + [package] }
        var next = children
        next.insert(package, at: index)
        return next
    }

    /// `localeCompare(…, { numeric: true, sensitivity: "base" })`.
    static func naturalCompare(_ first: String, _ second: String) -> ComparisonResult {
        first.compare(
            second, options: [.numeric, .caseInsensitive, .diacriticInsensitive], range: nil,
            locale: Locale(identifier: "en_US"))
    }
}
