import Foundation

/// Which kind of size the sheet chose.
public enum ImageSizeMode: String, CaseIterable, Sendable, Codable {
    case actual, fitWithin, scale, custom
}

/// The Convert Images sheet as last used, kept in the preferences. Each kind of size keeps its own value, so going
/// from one to another and back finds it as it was.
public struct ConvertImagesSettings: Hashable, Sendable, Codable {
    public var format: ImageFormat
    /// 0 to 1.
    public var quality: Double
    public var sizeMode: ImageSizeMode
    public var fitWithin: Int
    public var scale: Int
    public var customWidth: Int
    public var customHeight: Int
    public var customUnit: ImageSizeUnit
    public var proportional: Bool
    public var keepMetadata: Bool
    public var removeLocation: Bool

    public init(
        format: ImageFormat = .jpeg, quality: Double = ImageConversion.defaultQuality,
        sizeMode: ImageSizeMode = .actual,
        fitWithin: Int = 1920, scale: Int = 50, customWidth: Int = 1920, customHeight: Int = 1080,
        customUnit: ImageSizeUnit = .pixels, proportional: Bool = true, keepMetadata: Bool = true,
        removeLocation: Bool = false
    ) {
        self.format = format
        self.quality = quality
        self.sizeMode = sizeMode
        self.fitWithin = fitWithin
        self.scale = scale
        self.customWidth = customWidth
        self.customHeight = customHeight
        self.customUnit = customUnit
        self.proportional = proportional
        self.keepMetadata = keepMetadata
        self.removeLocation = removeLocation
    }

    public static let defaults = ConvertImagesSettings()

    public var size: ImageSize {
        switch sizeMode {
        case .actual: .actual
        case .fitWithin: .fitWithin(fitWithin)
        case .scale: .scale(scale)
        case .custom: .custom(width: customWidth, height: customHeight, unit: customUnit, proportional: proportional)
        }
    }

    public var options: ImageConversionOptions {
        ImageConversionOptions(
            format: format, quality: quality, size: size, keepMetadata: keepMetadata,
            removeLocation: keepMetadata && removeLocation)
    }

    /// The largest custom size typed, in pixels: past what any format holds.
    public static let maxPixels = 65_535

    /// Read leniently: a value missing or out of its range takes its default, so a damaged or older file never
    /// stops the sheet from opening.
    public static func sanitize(_ value: JSONNode?) -> ConvertImagesSettings {
        let record = value?.object ?? [:]
        let d = defaults
        func pick<Choice: RawRepresentable>(_ key: String, _ fallback: Choice) -> Choice
        where Choice.RawValue == String {
            record[key]?.string.flatMap { Choice(rawValue: $0) } ?? fallback
        }
        func whole(_ key: String, _ fallback: Int, _ range: ClosedRange<Int>) -> Int {
            guard let number = record[key]?.integer, Double(range.lowerBound) <= number,
                number <= Double(range.upperBound)
            else { return fallback }
            return Int(number)
        }
        let quality = record["quality"]?.number.flatMap { (0...1).contains($0) ? $0 : nil } ?? d.quality
        let unit: ImageSizeUnit = pick("customUnit", d.customUnit)
        let customRange = unit == .percent ? 1...100 : 1...maxPixels
        let widthFallback = unit == .percent ? 100 : d.customWidth
        let heightFallback = unit == .percent ? 100 : d.customHeight
        return ConvertImagesSettings(
            format: pick("format", d.format), quality: quality, sizeMode: pick("sizeMode", d.sizeMode),
            fitWithin: ImageSize.fitWithinSides.contains(whole("fitWithin", d.fitWithin, 1...maxPixels))
                ? whole("fitWithin", d.fitWithin, 1...maxPixels) : d.fitWithin,
            scale: ImageSize.scalePercentages.contains(whole("scale", d.scale, 1...100))
                ? whole("scale", d.scale, 1...100) : d.scale,
            customWidth: whole("customWidth", widthFallback, customRange),
            customHeight: whole("customHeight", heightFallback, customRange), customUnit: unit,
            proportional: record["proportional"]?.bool ?? d.proportional,
            keepMetadata: record["keepMetadata"]?.bool ?? d.keepMetadata,
            removeLocation: record["removeLocation"]?.bool ?? d.removeLocation)
    }
}
