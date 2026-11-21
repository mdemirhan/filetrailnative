import Foundation

/// The Convert Images sheet's state: what it chose, what it read of the pictures, and what that lets it offer, say
/// and do. No picture is ever made larger, in its width or its height.
public struct ConvertImagesSheet: Equatable, Sendable {
    public private(set) var settings: ConvertImagesSettings
    /// How many pictures are converted.
    public let count: Int
    /// One per picture, nil for one that can't be read; nil while they are being read.
    public private(set) var infos: [ImageInfo?]?
    /// Said under the custom size after a value was brought back to what is allowed, until the next change.
    public private(set) var customNote: String?
    /// The custom size the sheet opened with, when it was made smaller only to fit this one picture and has not been
    /// edited since: it is still the one remembered for the pictures to come.
    private var customAsRemembered: PixelSize?
    /// The formats offered: those this Mac can write.
    public let formats: [ImageFormat]

    /// `formats` are the ones the Mac can write; a format chosen last time that isn't among them gives way to the
    /// first that is.
    public init(
        settings: ConvertImagesSettings, count: Int, infos: [ImageInfo?]? = nil,
        formats: [ImageFormat] = ImageFormat.allCases
    ) {
        self.settings = settings
        self.count = count
        self.infos = infos
        self.formats = formats
        if !formats.contains(settings.format), let first = formats.first { self.settings.format = first }
        if let infos { read(infos) }
    }

    // MARK: The pictures

    /// What was read of the pictures, once it is.
    public mutating func read(_ infos: [ImageInfo?]) {
        self.infos = infos
        // An exact custom size taken from another selection is made to fit this one's picture.
        if settings.sizeMode == .custom, single != nil { fitCustomToThePicture() }
    }

    /// The custom size made to fit the one picture, the size it was kept for the next pictures.
    private mutating func fitCustomToThePicture() {
        let before = PixelSize(width: settings.customWidth, height: settings.customHeight)
        let remembered = customAsRemembered
        guard settleCustom() else { return }
        customAsRemembered = remembered ?? before
    }

    /// The settings to remember once Convert is pressed: what the sheet shows, but a custom size it only shrank to
    /// fit this one picture stays as it was, so a small picture converted between two batches doesn't make the next
    /// batch its size.
    public var settingsToRemember: ConvertImagesSettings {
        var remembered = settings
        if let size = customAsRemembered {
            remembered.customWidth = size.width
            remembered.customHeight = size.height
        }
        return remembered
    }

    public var isReading: Bool { infos == nil }

    /// The sizes read, upright.
    public var sizes: [PixelSize] { infos?.compactMap { $0?.size } ?? [] }

    /// The one picture's size, when there is one.
    public var single: PixelSize? { count == 1 ? sizes.first : nil }

    /// How many couldn't be read as pictures.
    public var unreadableCount: Int { infos?.filter { $0 == nil }.count ?? 0 }

    // MARK: Format

    public mutating func choose(format: ImageFormat) {
        guard formats.contains(format) else { return }
        settings.format = format
        customNote = nil
    }

    public mutating func set(quality: Double) {
        settings.quality = min(max(quality, 0), 1)
    }

    /// "80%".
    public var qualityText: String { "\(Int((settings.quality * 100).rounded()))%" }

    // MARK: Size

    /// A choice of the size pop-up; nil in `sizeChoices` is a line between them.
    public enum SizeChoice: Hashable, Sendable {
        case actual
        case fitWithin(Int)
        case scale(Int)
        case custom

        public var title: String {
            switch self {
            case .actual: "Actual Size"
            case .fitWithin(let side): "Fit Within \(side) px"
            case .scale(let percent): "\(percent)%"
            case .custom: "Custom\u{2026}"
            }
        }
    }

    public static let sizeChoices: [SizeChoice?] =
        [.actual, nil] + ImageSize.fitWithinSides.map { .fitWithin($0) } + [nil]
        + ImageSize.scalePercentages.map { .scale($0) } + [nil, .custom]

    public var selectedSizeChoice: SizeChoice {
        switch settings.sizeMode {
        case .actual: .actual
        case .fitWithin: .fitWithin(settings.fitWithin)
        case .scale: .scale(settings.scale)
        case .custom: .custom
        }
    }

    /// A Fit Within size the one picture is already inside does nothing, so it isn't offered.
    public func isEnabled(_ choice: SizeChoice) -> Bool {
        guard case .fitWithin(let side) = choice, let single else { return true }
        return side < single.longestSide
    }

    /// What the pop-up shows beside a size it doesn't offer: "This image is 2400 px".
    public func disabledNote(_ choice: SizeChoice) -> String? {
        guard !isEnabled(choice), let single else { return nil }
        return "This image is \(single.longestSide) px"
    }

    public mutating func choose(size choice: SizeChoice) {
        customNote = nil
        switch choice {
        case .actual: settings.sizeMode = .actual
        case .fitWithin(let side):
            settings.sizeMode = .fitWithin
            settings.fitWithin = side
        case .scale(let percent):
            settings.sizeMode = .scale
            settings.scale = percent
        case .custom:
            settings.sizeMode = .custom
            fitCustomToThePicture()
            customNote = nil
        }
    }

    // MARK: Custom size

    /// The width as typed. For one picture with Scale Proportionally, the height follows it.
    public mutating func type(width: Int) {
        customNote = nil
        customAsRemembered = nil
        settings.customWidth = width
        guard settings.proportional else { return }
        if settings.customUnit == .percent {
            settings.customHeight = width
        } else if let single {
            settings.customHeight = max(
                1, Int((Double(width) * Double(single.height) / Double(single.width)).rounded()))
        }
    }

    /// The height as typed. For one picture with Scale Proportionally, the width follows it.
    public mutating func type(height: Int) {
        customNote = nil
        customAsRemembered = nil
        settings.customHeight = height
        guard settings.proportional else { return }
        if settings.customUnit == .percent {
            settings.customWidth = height
        } else if let single {
            settings.customWidth = max(
                1, Int((Double(height) * Double(single.width) / Double(single.height)).rounded()))
        }
    }

    /// When a field is left: a percentage over 100, or a width or height larger than the one picture's, is brought
    /// back to it, with a note. True when something changed.
    @discardableResult
    public mutating func settleCustom() -> Bool {
        var settled = settings
        settled.customWidth = max(1, settled.customWidth)
        settled.customHeight = max(1, settled.customHeight)
        var note: String?
        switch settled.customUnit {
        case .percent:
            if settled.customWidth > 100 || settled.customHeight > 100 { note = "At most 100%" }
            settled.customWidth = min(settled.customWidth, 100)
            settled.customHeight = min(settled.customHeight, 100)
        case .pixels:
            settled.customWidth = min(settled.customWidth, ConvertImagesSettings.maxPixels)
            settled.customHeight = min(settled.customHeight, ConvertImagesSettings.maxPixels)
            guard let single else { break }
            if settled.customWidth > single.width || settled.customHeight > single.height {
                note = "At most \(single.text), this image\u{2019}s size"
                if settled.proportional {
                    // The box shrinks to the picture, keeping its shape.
                    let factor = min(
                        1, Double(single.width) / Double(settled.customWidth),
                        Double(single.height) / Double(settled.customHeight))
                    settled.customWidth = min(single.width, Int((Double(settled.customWidth) * factor).rounded()))
                    settled.customHeight = min(single.height, Int((Double(settled.customHeight) * factor).rounded()))
                }
                settled.customWidth = max(1, min(settled.customWidth, single.width))
                settled.customHeight = max(1, min(settled.customHeight, single.height))
            }
        }
        let changed = settled != settings
        settings = settled
        customNote = note
        return changed
    }

    /// Pixels or percent. Percent starts at 100% each way; pixels at the one picture's size, or the largest width
    /// and height among several.
    public mutating func choose(unit: ImageSizeUnit) {
        guard unit != settings.customUnit else { return }
        customNote = nil
        customAsRemembered = nil
        settings.customUnit = unit
        switch unit {
        case .percent:
            settings.customWidth = 100
            settings.customHeight = 100
        case .pixels:
            if let single {
                settings.customWidth = single.width
                settings.customHeight = single.height
            } else if !sizes.isEmpty {
                settings.customWidth = sizes.map(\.width).max() ?? settings.customWidth
                settings.customHeight = sizes.map(\.height).max() ?? settings.customHeight
            }
        }
    }

    /// Scale Proportionally: turned on for one picture, the height follows the width again.
    public mutating func set(proportional: Bool) {
        customNote = nil
        customAsRemembered = nil
        settings.proportional = proportional
        if proportional { type(width: settings.customWidth) }
    }

    // MARK: Metadata

    public mutating func set(keepMetadata: Bool) { settings.keepMetadata = keepMetadata }
    public mutating func set(removeLocation: Bool) { settings.removeLocation = removeLocation }

    /// Without metadata the location goes too: Remove Location shows checked and can't be changed.
    public var removesLocation: Bool { !settings.keepMetadata || settings.removeLocation }

    // MARK: What it says

    public var title: String { count == 1 ? "Convert Image" : "Convert \(FormatLocale.count(count)) Images" }

    public var outcome: ImageConversion.SizeOutcome { ImageConversion.outcome(sizes, settings.size) }

    /// What the size does: "4783 × 7174 → 1365 × 2048", or what it does to several.
    public var summary: String {
        guard infos != nil else { return "Reading the images\u{2019} sizes\u{2026}" }
        if count > 1, sizes.isEmpty { return "None of them can be opened as an image." }
        if count == 1 {
            guard let single else { return "It can\u{2019}t be opened as an image." }
            guard let target = ImageConversion.targetSize(single, settings.size) else {
                return "\(single.text) is smaller than \(settings.customWidth) \u{00D7} \(settings.customHeight)"
            }
            return target == single ? "\(single.text), kept at its size" : "\(single.text) \u{2192} \(target.text)"
        }
        let outcome = outcome
        let read = FormatLocale.count(sizes.count)
        if settings.sizeMode == .actual || outcome.smaller == 0, outcome.tooSmall == 0 {
            return settings.sizeMode == .actual
                ? "\(read) images, each kept at its size" : "\(read) images, all already fit and keep their size"
        }
        if outcome.unchanged == 0, outcome.tooSmall == 0 { return "\(read) images, each made smaller" }
        var parts = ["\(FormatLocale.count(outcome.smaller)) made smaller"]
        if outcome.unchanged > 0 {
            parts.append("\(FormatLocale.count(outcome.unchanged)) already fit and keep their size")
        }
        return "\(read) images: " + parts.joined(separator: ", ")
    }

    /// What keeps it from converting, or may surprise: each a line beside a warning sign.
    public var warnings: [String] {
        var lines: [String] = []
        let outcome = outcome
        if outcome.tooSmall > 0 {
            let box = "\(settings.customWidth) \u{00D7} \(settings.customHeight)"
            lines.append(
                outcome.tooSmall == 1
                    ? "1 of the images is smaller than \(box), and images are never made larger"
                    : "\(FormatLocale.count(outcome.tooSmall)) of the images are smaller than \(box), and images are never "
                        + "made larger")
        }
        if case .custom(_, _, .pixels, false) = settings.size, count > 1, ImageConversion.shapesDiffer(sizes) {
            lines.append("The images aren\u{2019}t all the same shape, so one exact size stretches them differently")
        }
        if unreadableCount > 0, !sizes.isEmpty {
            lines.append(
                unreadableCount == 1
                    ? "1 of them can\u{2019}t be opened as an image"
                    : "\(FormatLocale.count(unreadableCount)) of them can\u{2019}t be opened as images")
        }
        return lines
    }

    /// What the format does to these pictures.
    public var notes: [String] {
        let infos = (infos ?? []).compactMap { $0 }
        var lines: [String] = []
        let format = settings.format
        if !format.keepsTransparency, infos.contains(where: \.hasAlpha) {
            lines.append("\(format.title) has no transparency: transparent parts become white.")
        }
        if !format.keepsHDR, infos.contains(where: \.hasGainMap) {
            lines.append("\(format.title) keeps no HDR: HDR photos are saved in standard range.")
        }
        if infos.contains(where: { $0.frameCount > 1 }) {
            lines.append("Of an animation, or a file of several pages, only the first is converted.")
        }
        return lines
    }

    /// Whether Convert can be pressed: an exact size any picture is smaller than can't be met, the sizes must be
    /// known for any size but the actual one, and once they are read at least one must be a picture.
    public var canConvert: Bool {
        guard count > 0 else { return false }
        if infos != nil, sizes.isEmpty { return false }
        if settings.sizeMode == .actual { return true }
        return infos != nil && outcome.tooSmall == 0
    }

    public var options: ImageConversionOptions { settings.options }
}
