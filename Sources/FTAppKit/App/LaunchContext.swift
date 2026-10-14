// Port of apps/desktop/src/main/launchContext.ts
import FTFoundation
import Foundation

public enum LaunchContext {
    /// `resolveStartupFolderPath`: the folder named by `--folder <p>`, `--folder=<p>`, or the first positional
    /// argument that is not the app's own path; `~` is expanded and the path must be a directory.
    public static func resolveStartupFolderPath(
        argv: [String], cwd: String, argvOffset: Int = 1, homePath: String = NSHomeDirectory(), appPath: String? = nil,
        isDirectory: (String) -> Bool = LaunchContext.isDirectoryOnDisk
    ) -> String? {
        let userArgs = Array(argv.dropFirst(argvOffset))
        guard
            let rawPath = folderOption(userArgs)
                ?? positionalFolderArgument(userArgs, cwd: cwd, homePath: homePath, appPath: appPath)
        else { return nil }
        let candidate = resolveLaunchPath(rawPath, cwd: cwd, homePath: homePath)
        return isDirectory(candidate) ? candidate : nil
    }

    /// `resolveLaunchWorkingDirectory`.
    public static func resolveWorkingDirectory(envPWD: String?, cwd: String) -> String {
        if !cwd.isEmpty, cwd.hasPrefix("/") { return cwd }
        if let envPWD, envPWD.hasPrefix("/") { return envPWD }
        return cwd
    }

    public static func isDirectoryOnDisk(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func folderOption(_ argv: [String]) -> String? {
        for (index, value) in argv.enumerated() where !value.isEmpty {
            if value == "--folder" {
                return argv.indices.contains(index + 1) ? argv[index + 1] : nil
            }
            if value.hasPrefix("--folder=") {
                let folder = String(value.dropFirst("--folder=".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                return folder.isEmpty ? nil : folder
            }
        }
        return nil
    }

    private static func positionalFolderArgument(_ argv: [String], cwd: String, homePath: String, appPath: String?)
        -> String?
    {
        for value in argv {
            if value.isEmpty || value.hasPrefix("-") { continue }
            if let appPath, resolveLaunchPath(value, cwd: cwd, homePath: homePath) == appPath { continue }
            return value
        }
        return nil
    }

    private static func resolveLaunchPath(_ rawPath: String, cwd: String, homePath: String) -> String {
        if rawPath == "~" { return homePath }
        if rawPath.hasPrefix("~/") { return NodePath.resolve(NodePath.join(homePath, String(rawPath.dropFirst(2)))) }
        return rawPath.hasPrefix("/") ? rawPath : NodePath.resolve(NodePath.join(cwd, rawPath))
    }
}
