// Port of apps/desktop/src/main/logRotation.ts
import Foundation

/// Rotation of `app.log` into `app.1.log` … `app.<n-1>.log`.
public enum LogRotation {
    /// `readFileSize`: the size of the file, 0 when it cannot be read.
    public static func fileSize(_ path: String) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }

    /// `rotateLogFiles`: the oldest file is dropped, each other moves up one, and the current one becomes `.1`. A
    /// failure to move one file does not stop the rest.
    public static func rotate(_ path: String, maxFiles: Int) {
        let manager = FileManager.default
        if maxFiles <= 1 {
            try? manager.removeItem(atPath: path)
            return
        }
        try? manager.removeItem(atPath: rotatedPath(path, maxFiles - 1))
        var index = maxFiles - 2
        while index >= 1 {
            move(rotatedPath(path, index), to: rotatedPath(path, index + 1))
            index -= 1
        }
        move(path, to: rotatedPath(path, 1))
    }

    /// `resolveRotatedLogPath`: `app.log` rotated once is `app.1.log`.
    public static func rotatedPath(_ path: String, _ index: Int) -> String {
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension
        let name = url.deletingPathExtension().lastPathComponent
        let file = ext.isEmpty ? "\(name).\(index)" : "\(name).\(index).\(ext)"
        return url.deletingLastPathComponent().appendingPathComponent(file).path
    }

    // `rename` replaces an existing target, as Node's does.
    private static func move(_ from: String, to: String) {
        _ = Darwin.rename(from, to)
    }
}
