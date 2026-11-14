/// The size View ▸ Make Bigger, Make Smaller and Default Size change, and the status bar's slider sets: the Icons
/// view's icon size, in steps of 8 points, and the Compact List's column width, in steps of 40. The List has none.
public struct ViewSize: Equatable, Sendable {
    public var value: Int
    public var range: ClosedRange<Int>
    /// Make Bigger and Make Smaller go to the next whole step.
    public var step: Int
    /// What Default Size goes back to.
    public var defaultValue: Int

    public init(value: Int, range: ClosedRange<Int>, step: Int, defaultValue: Int) {
        self.value = value
        self.range = range
        self.step = step
        self.defaultValue = defaultValue
    }

    /// The size of a view at a density; nil for the List.
    public static func of(
        _ mode: ExplorerViewMode, density: Density, iconSizes: DensitySizes, compactListWidths: DensitySizes,
        previewCounts: DensitySizes = .previewCountDefaults
    ) -> ViewSize? {
        switch mode {
        // Where the count is in `PreviewGrid.counts`: a step bigger is fewer, larger previews.
        case .previews:
            ViewSize(
                value: PreviewGrid.index(of: previewCounts[density]), range: 0...(PreviewGrid.counts.count - 1),
                step: 1, defaultValue: PreviewGrid.index(of: DensitySizes.previewCountDefaults[density]))
        case .icons:
            ViewSize(
                value: iconSizes[density], range: AppPreferenceLimits.iconSizeRange,
                step: AppPreferenceLimits.iconSizeStep, defaultValue: DensitySizes.iconDefaults[density])
        case .list:
            ViewSize(
                value: compactListWidths[density], range: AppPreferenceLimits.compactListWidthRange,
                step: AppPreferenceLimits.compactListWidthStep,
                defaultValue: DensitySizes.compactListDefaults[density])
        case .details:
            nil
        }
    }

    /// The next whole step above the size, within the range: 292 goes to 320 in steps of 40.
    public var bigger: Int {
        min(range.upperBound, max(range.lowerBound, (value / step + 1) * step))
    }

    /// The next whole step below the size, within the range: 292 goes to 280 in steps of 40.
    public var smaller: Int {
        max(range.lowerBound, min(range.upperBound, ((value + step - 1) / step - 1) * step))
    }

    /// The size after a step.
    public func stepped(_ change: Change) -> Int {
        switch change {
        case .bigger: bigger
        case .smaller: smaller
        case .reset: defaultValue
        }
    }

    /// Which of the three would change the size.
    public var steps: Steps {
        Steps(bigger: value < range.upperBound, smaller: value > range.lowerBound, reset: value != defaultValue)
    }

    public enum Change: Sendable {
        case bigger, smaller, reset

        /// The change a View menu command makes; nil for any other command.
        public init?(_ command: AppCommand) {
            switch command {
            case .increaseSize: self = .bigger
            case .decreaseSize: self = .smaller
            case .resetSize: self = .reset
            default: return nil
            }
        }
    }

    /// Which of Make Bigger, Make Smaller and Default Size would change the size on screen.
    public struct Steps: Equatable, Sendable {
        public var bigger: Bool
        public var smaller: Bool
        public var reset: Bool

        public init(bigger: Bool, smaller: Bool, reset: Bool) {
            self.bigger = bigger
            self.smaller = smaller
            self.reset = reset
        }

        /// The List: none of them does anything.
        public static let unavailable = Steps(bigger: false, smaller: false, reset: false)

        public func allows(_ change: Change) -> Bool {
            switch change {
            case .bigger: bigger
            case .smaller: smaller
            case .reset: reset
            }
        }
    }
}
