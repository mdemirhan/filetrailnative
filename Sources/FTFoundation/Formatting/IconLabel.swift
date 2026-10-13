// Port of apps/desktop/src/renderer/lib/iconLabel.ts (shortenNameInMiddle; the DOM measuring is the view's)
import Foundation

/// Names under icons wrap onto at most two lines. A longer name is shortened like Finder does: the
/// first line stays as it wraps, and the rest loses its middle so that the end of the name and the
/// extension stay readable: "Panorama" / "Miradouro…Monte.jpeg".
public enum IconLabel {
    public static let ellipsis = "…"
    /// How much of the name before the extension is kept at the end.
    public static let tailStemCharacters = 5
    public static let lineCount = 2
    /// Fitted labels remembered before the cache starts over.
    public static let fittedLabelCacheMax = 4000

    /// Shortens `name` in the middle until `fits` accepts it, keeping as much of its start as
    /// possible. `fits` must not accept a longer text after refusing a shorter one (true of a single
    /// line). A name that cannot be made to fit is returned whole and left to the label's own clipping.
    /// The text width is the caller's (AppKit measures it with the label's font).
    public static func shortenInMiddle(name: String, extension fileExtension: String, fits: (String) -> Bool) -> String
    {
        if fits(name) {
            return name
        }
        let parts = DisplayName.split(name, extension: fileExtension)
        // Code points, so a character outside the basic plane is never cut in half.
        let stem = Array(parts.stem.unicodeScalars)
        func text(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
            var view = String.UnicodeScalarView()
            view.append(contentsOf: scalars)
            return String(view)
        }
        // Less of the end is kept when keeping all of it leaves no room for a start.
        let longestTail = min(tailStemCharacters, stem.count / 2)
        var tailLength = longestTail
        while tailLength >= 0 {
            let tail = text(stem[(stem.count - tailLength)...]) + parts.extensionSuffix
            func shortened(_ headLength: Int) -> String {
                JSString.trimmedEnd(text(stem[..<headLength])) + ellipsis + tail
            }

            // The longest start of the name that still fits, found by halving.
            var low = 1
            var high = stem.count - tailLength - 1
            var best: String?
            while low <= high {
                let middle = (low + high) / 2
                let candidate = shortened(middle)
                if fits(candidate) {
                    best = candidate
                    low = middle + 1
                } else {
                    high = middle - 1
                }
            }
            if let best {
                return best
            }
            tailLength -= 1
        }
        return name
    }
}
