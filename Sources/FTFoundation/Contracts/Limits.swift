// Port of packages/contracts/src/limits.ts
import Foundation

/// Limits the original's IPC contract held requests to.
public enum Limits {
    /// Enough for selecting everything in a large folder; the bound only keeps a runaway payload out.
    public static let maxPathsPerRequest = 100_000

    /// How many dragged items are drawn; Finder draws no more than fit on screen.
    public static let maxFileDragImages = 200
}
