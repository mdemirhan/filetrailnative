import Foundation

/// Whether the viewer's text area is light or dark: its own setting, apart from the app's.
public enum TextViewerAppearance: String, CaseIterable, Sendable {
    case matchApp
    case light
    case dark

    public var label: String {
        switch self {
        case .matchApp: "Match App"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

/// The colors of the viewer's text area.
public struct TextViewerTheme: Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let appearance: ThemeAppearance
    public let background: RGBA
    public let text: RGBA
    public let gutterText: RGBA
    public let currentLine: RGBA
    public let selection: RGBA
    public let findMatch: RGBA
    let colors: [SyntaxKind: RGBA]

    public func color(for kind: SyntaxKind) -> RGBA {
        colors[kind] ?? text
    }

    public static func == (a: TextViewerTheme, b: TextViewerTheme) -> Bool { a.id == b.id }

    init(
        _ id: String, _ name: String, _ appearance: ThemeAppearance, background: String, text: String, gutter: String,
        currentLine: String, selection: String, findMatch: String, _ colors: [SyntaxKind: String]
    ) {
        self.id = id
        self.name = name
        self.appearance = appearance
        self.background = RGBA(hex: background) ?? .black
        self.text = RGBA(hex: text) ?? .black
        self.gutterText = RGBA(hex: gutter) ?? .black
        self.currentLine = RGBA(hex: currentLine) ?? .black
        self.selection = RGBA(hex: selection) ?? .black
        self.findMatch = RGBA(hex: findMatch) ?? .black
        self.colors = colors.compactMapValues { RGBA(hex: $0) }
    }
}

extension TextViewerTheme {
    public static let defaultLightID = "paper"
    public static let defaultDarkID = "graphite"

    public static let light: [TextViewerTheme] = [paper, mist, sand]
    public static let dark: [TextViewerTheme] = [graphite, midnight, ink]

    /// The theme of `id` among those of `appearance`, else that appearance's default.
    public static func named(_ id: String, appearance: ThemeAppearance) -> TextViewerTheme {
        let themes = appearance == .light ? light : dark
        return themes.first { $0.id == id } ?? themes[0]
    }

    static let paper = TextViewerTheme(
        "paper", "Paper", .light, background: "#fbfbfc", text: "#24292f", gutter: "#a1a1a8", currentLine: "#eef3fb",
        selection: "#cfe0fa", findMatch: "#ffe08a",
        [
            .keyword: "#a3237f", .type: "#1f5fb4", .string: "#b4351f", .comment: "#6e7781", .number: "#6f3cc4",
            .literal: "#a3237f", .attribute: "#8a5a00", .variable: "#0b7a75", .function: "#2e6d2e", .tag: "#1f5fb4",
            .property: "#1f5fb4", .heading: "#1f5fb4", .emphasis: "#5a3e8a", .strong: "#24292f", .code: "#b4351f",
            .link: "#0a64d8", .inserted: "#2e6d2e", .deleted: "#b4351f", .meta: "#6e7781",
        ])
    static let mist = TextViewerTheme(
        "mist", "Mist", .light, background: "#eef2f6", text: "#1f2933", gutter: "#8a96a3", currentLine: "#e2e9f1",
        selection: "#c6d6ea", findMatch: "#ffd666",
        [
            .keyword: "#4f46e5", .type: "#0b7a75", .string: "#c2410c", .comment: "#6b7785", .number: "#9b2c6b",
            .literal: "#4f46e5", .attribute: "#7c5800", .variable: "#9b2c6b", .function: "#0f6fae", .tag: "#0b7a75",
            .property: "#0f6fae", .heading: "#4f46e5", .emphasis: "#5b4d8a", .strong: "#1f2933", .code: "#c2410c",
            .link: "#0f6fae", .inserted: "#1f7a3a", .deleted: "#b42318", .meta: "#6b7785",
        ])
    static let sand = TextViewerTheme(
        "sand", "Sand", .light, background: "#f7f1e3", text: "#3b3226", gutter: "#a3957c", currentLine: "#efe6d2",
        selection: "#e3d3ad", findMatch: "#ffcf4a",
        [
            .keyword: "#9b2c6b", .type: "#8a5a00", .string: "#2f7d32", .comment: "#8c7d64", .number: "#a8431a",
            .literal: "#9b2c6b", .attribute: "#8a5a00", .variable: "#1d6e8a", .function: "#1d6e8a", .tag: "#8a5a00",
            .property: "#1d6e8a", .heading: "#9b2c6b", .emphasis: "#6b4f2a", .strong: "#3b3226", .code: "#2f7d32",
            .link: "#1d6e8a", .inserted: "#2f7d32", .deleted: "#a8431a", .meta: "#8c7d64",
        ])
    static let graphite = TextViewerTheme(
        "graphite", "Graphite", .dark, background: "#1e1f24", text: "#e1e2e6", gutter: "#6c7079",
        currentLine: "#2a2c33",
        selection: "#3a4a66", findMatch: "#8a6d1f",
        [
            .keyword: "#fc6aa8", .type: "#c9a6ff", .string: "#ff8a72", .comment: "#7d8794", .number: "#e2c97a",
            .literal: "#fc6aa8", .attribute: "#ffa657", .variable: "#6fb3ff", .function: "#6fcfb6", .tag: "#6fb3ff",
            .property: "#6fb3ff", .heading: "#6fb3ff", .emphasis: "#c9a6ff", .strong: "#ffd27a", .code: "#ff8a72",
            .link: "#6fcfb6", .inserted: "#7ad98a", .deleted: "#ff7b72", .meta: "#7d8794",
        ])
    static let midnight = TextViewerTheme(
        "midnight", "Midnight", .dark, background: "#0f1524", text: "#c8d3f5", gutter: "#4b5878",
        currentLine: "#18213a",
        selection: "#2b3b66", findMatch: "#7a6420",
        [
            .keyword: "#bb9af7", .type: "#7dcfff", .string: "#9ece6a", .comment: "#5f6d91", .number: "#ff9e64",
            .literal: "#ff9e64", .attribute: "#e0af68", .variable: "#f7768e", .function: "#7aa2f7", .tag: "#f7768e",
            .property: "#73daca", .heading: "#7aa2f7", .emphasis: "#bb9af7", .strong: "#e0af68", .code: "#9ece6a",
            .link: "#7dcfff", .inserted: "#9ece6a", .deleted: "#f7768e", .meta: "#5f6d91",
        ])
    static let ink = TextViewerTheme(
        "ink", "Ink", .dark, background: "#000000", text: "#f2f2f2", gutter: "#6b6b6b", currentLine: "#161616",
        selection: "#33415c", findMatch: "#806a00",
        [
            .keyword: "#ffcf4a", .type: "#5ad1ff", .string: "#8cf08c", .comment: "#8a8a8a", .number: "#ff9ef5",
            .literal: "#ff9ef5", .attribute: "#ffb86b", .variable: "#5ad1ff", .function: "#ffffff", .tag: "#5ad1ff",
            .property: "#ffcf4a", .heading: "#ffcf4a", .emphasis: "#ff9ef5", .strong: "#ffffff", .code: "#8cf08c",
            .link: "#5ad1ff", .inserted: "#8cf08c", .deleted: "#ff6b6b", .meta: "#8a8a8a",
        ])
}
