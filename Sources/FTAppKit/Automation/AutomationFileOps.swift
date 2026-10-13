// Port of the fs step of tools/capture/electron/driver.ts; no TypeScript source.
#if DEBUG
    import Foundation

    /// A scenario's `fs` step: the fixture changed from outside the app, for the folder-watch flows.
    /// Only a scratch copy is changed (run.sh makes one for a scenario with `setup.scratch` and names it
    /// in `FILETRAIL_SCENARIO_ROOT`), and only inside it.
    enum AutomationFileOps {
        struct Failure: Error, Equatable, CustomStringConvertible {
            let description: String
        }

        static func perform(
            _ op: Scenario.FileOp, scenario: Scenario,
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) throws {
            guard let scratch = environment["FILETRAIL_SCENARIO_ROOT"], !scratch.isEmpty else {
                throw Failure(description: "fs steps change only a scratch copy: give the scenario setup.scratch")
            }
            let root = scenario.resolve(".", environment: environment).path
            func inside(_ path: String) throws -> URL {
                let url = scenario.resolve(path, environment: environment)
                guard url.path.hasPrefix(root + "/") else {
                    throw Failure(description: "\(path) is outside the scenario's folder")
                }
                return URL(fileURLWithPath: url.path)
            }
            let fm = FileManager.default
            let date = scenario.nowDate
            func dated(_ url: URL) throws {
                guard let date else { return }
                try fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
            }
            switch op {
            case .create(let path, let contents, let directory):
                let url = try inside(path)
                guard !fm.fileExists(atPath: url.path) else { throw Failure(description: "\(path) already exists") }
                if directory {
                    try fm.createDirectory(at: url, withIntermediateDirectories: false)
                } else {
                    try Data(contents.utf8).write(to: url, options: .withoutOverwriting)
                }
                try dated(url)
            case .write(let path, let contents, let append):
                let url = try inside(path)
                if append, let handle = try? FileHandle(forWritingTo: url) {
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: Data(contents.utf8))
                } else {
                    try Data(contents.utf8).write(to: url)
                }
                try dated(url)
            case .rename(let path, let target):
                let source = try inside(path)
                let destination = try inside(target)
                guard !fm.fileExists(atPath: destination.path) else {
                    throw Failure(description: "\(target) already exists")
                }
                try fm.moveItem(at: source, to: destination)
            case .delete(let path):
                try fm.removeItem(at: try inside(path))
            case .chmod(let path, let mode):
                guard let bits = Int(mode, radix: 8) else { throw Failure(description: "bad mode \(mode)") }
                try fm.setAttributes([.posixPermissions: bits], ofItemAtPath: try inside(path).path)
            case .lock(let path, let locked):
                try fm.setAttributes([.immutable: locked], ofItemAtPath: try inside(path).path)
            }
        }
    }
#endif
