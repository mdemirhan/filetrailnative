import Foundation

/// Limits requests are held to.
public enum Limits {
    /// Enough for selecting everything in a large folder; the bound only keeps a runaway payload out.
    public static let maxPathsPerRequest = 100_000

    /// How many dragged items are drawn; the rest go along unseen.
    public static let maxFileDragImages = 5
}
