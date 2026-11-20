import Foundation

/// The viewer's own look, one for the whole app: its appearance apart from the app's, a theme for each, the font size,
/// and whether lines wrap and are numbered.
public struct TextViewerSettings: Codable, Equatable, Sendable {
    public var appearance: String
    public var lightTheme: String
    public var darkTheme: String
    public var fontSize: Double
    public var wrapLines: Bool
    public var lineNumbers: Bool
    /// A file opens to Edit rather than Read: the one chosen last.
    public var opensForEditing: Bool

    public static let fontSizes: ClosedRange<Double> = 9...32
    public static let defaults = TextViewerSettings()

    public init(
        appearance: TextViewerAppearance = .matchApp, lightTheme: String = TextViewerTheme.defaultLightID,
        darkTheme: String = TextViewerTheme.defaultDarkID, fontSize: Double = 13, wrapLines: Bool = true,
        lineNumbers: Bool = true, opensForEditing: Bool = false
    ) {
        self.appearance = appearance.rawValue
        self.lightTheme = lightTheme
        self.darkTheme = darkTheme
        self.fontSize = fontSize
        self.wrapLines = wrapLines
        self.lineNumbers = lineNumbers
        self.opensForEditing = opensForEditing
    }

    public var viewerAppearance: TextViewerAppearance {
        get { TextViewerAppearance(rawValue: appearance) ?? .matchApp }
        set { appearance = newValue.rawValue }
    }

    /// The theme the text area takes, with the app in `appAppearance`.
    public func theme(appAppearance: ThemeAppearance) -> TextViewerTheme {
        let shown: ThemeAppearance =
            switch viewerAppearance {
            case .matchApp: appAppearance
            case .light: .light
            case .dark: .dark
            }
        return TextViewerTheme.named(shown == .light ? lightTheme : darkTheme, appearance: shown)
    }

    /// A saved value read back: anything not understood takes its default.
    public static func sanitize(_ value: JSONNode?) -> TextViewerSettings {
        let record = value?.object ?? [:]
        let d = defaults
        let appearance = record["appearance"]?.string.flatMap(TextViewerAppearance.init(rawValue:)) ?? .matchApp
        let light = record["lightTheme"]?.string.flatMap { id in TextViewerTheme.light.first { $0.id == id }?.id }
        let dark = record["darkTheme"]?.string.flatMap { id in TextViewerTheme.dark.first { $0.id == id }?.id }
        let size = record["fontSize"]?.number.flatMap { fontSizes.contains($0) ? $0.rounded() : nil }
        return TextViewerSettings(
            appearance: appearance, lightTheme: light ?? d.lightTheme, darkTheme: dark ?? d.darkTheme,
            fontSize: size ?? d.fontSize, wrapLines: record["wrapLines"]?.bool ?? d.wrapLines,
            lineNumbers: record["lineNumbers"]?.bool ?? d.lineNumbers,
            opensForEditing: record["opensForEditing"]?.bool ?? d.opensForEditing)
    }
}

/// What a pane shows of a file, kept with the pane in a saved tab and a workspace.
public struct ViewerPreference: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable {
        /// The file in place of the pane's folder.
        case inPlace
        /// The other pane's selected file.
        case following
        /// One file, whatever the other pane selects.
        case pinned
    }

    public var mode: Mode
    /// The file shown. A following viewer's is selected in the other pane again when the window comes back.
    @NullEncoded public var path: String?
    /// Markdown shown as its preview rather than its source.
    public var preview: Bool
    /// The file was being edited, not only read.
    public var editing: Bool

    public init(mode: Mode, path: String?, preview: Bool = true, editing: Bool = false) {
        self.mode = mode
        self.path = path
        self.preview = preview
        self.editing = editing
    }

    /// A saved record read back, or nil for none or one not understood.
    public static func sanitize(_ value: JSONNode?) -> ViewerPreference? {
        guard let record = value?.object, let mode = record["mode"]?.string.flatMap(Mode.init(rawValue:)) else {
            return nil
        }
        let path = record["path"]?.string.flatMap { $0.hasPrefix("/") ? $0 : nil }
        if mode != .following && path == nil { return nil }
        return ViewerPreference(
            mode: mode, path: path, preview: record["preview"]?.bool ?? true,
            editing: record["editing"]?.bool ?? false)
    }
}
