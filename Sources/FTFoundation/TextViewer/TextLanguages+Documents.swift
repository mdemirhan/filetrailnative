import Foundation

extension TextLanguages {
    /// Markup, style sheets and the formats people write documents in.
    static let documents: [TextLanguage] = [
        TextLanguage(
            "html", "HTML", .markup,
            extensions: [
                "html", "htm", "xhtml", "shtml", "vue", "svelte", "hbs", "handlebars", "mustache", "jinja", "j2",
                "twig", "liquid",
            ]),
        TextLanguage(
            "xml", "XML", .markup,
            extensions: [
                "xml", "plist", "svg", "xsd", "xsl", "xslt", "rss", "atom", "xib", "storyboard", "entitlements",
                "csproj",
                "vbproj", "fsproj", "props", "targets", "resx", "xaml", "wsdl", "kml", "gpx", "dae", "opml",
            ]),
        TextLanguage(
            "markdown", "Markdown", .markdown, extensions: ["md", "markdown", "mdown", "mkd", "mkdn", "mdx"],
            hasPreview: true),
        TextLanguage(
            "tex", "LaTeX",
            code {
                $0.lineComments = [Array("%".utf16)]
                $0.attributePrefixes = [Char.backslash]
                $0.functionCalls = false
            }, extensions: ["tex", "sty", "cls", "bib", "ltx"]),
        TextLanguage("css", "CSS", .css(CSSRules()), extensions: ["css"]),
        TextLanguage(
            "scss", "SCSS",
            .css(
                {
                    var rules = CSSRules()
                    rules.lineComments = true
                    rules.variablePrefix = Char.dollar
                    return rules
                }()), extensions: ["scss", "sass"]),
        TextLanguage(
            "less", "Less",
            .css(
                {
                    var rules = CSSRules()
                    rules.lineComments = true
                    rules.variablePrefix = Char.at
                    return rules
                }()), extensions: ["less"]),
    ]
}
