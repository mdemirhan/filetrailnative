import AppKit

/// The pictures in a Markdown file's HTML: the `<img>` tags a README writes to give a picture a size or to center it,
/// often in a `<p align="center">`. The tags around them are left out, as a browser shows none; HTML with no picture
/// stays as it is written.
enum MarkdownHTML {
    struct Picture: Equatable {
        /// Where `src` points, read from the Markdown file's folder; nil when it can't be told.
        let url: URL?
        let alt: String
        /// The `width` and `height` given, in points; either may be missing.
        let width: CGFloat?
        let height: CGFloat?

        /// The size to show `picture` at: as given, the side not given in the picture's proportions.
        func size(of picture: NSSize) -> NSSize {
            switch (width, height) {
            case (let width?, let height?): NSSize(width: width, height: height)
            case (let width?, nil): NSSize(width: width, height: width * picture.height / max(picture.width, 1))
            case (nil, let height?): NSSize(width: height * picture.width / max(picture.height, 1), height: height)
            case (nil, nil): picture
            }
        }
    }

    enum Part: Equatable {
        case text(String)
        case picture(Picture)
    }

    nonisolated(unsafe) private static let imageTag = /<img\b[^>]*>/.ignoresCase()
    nonisolated(unsafe) private static let anyTag = /<\/?[A-Za-z][^>]*>/
    nonisolated(unsafe) private static let attribute =
        /([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))/
    nonisolated(unsafe) private static let centered = /\balign\s*=\s*["']?center\b/.ignoresCase()

    /// `html` as its text and pictures, the other tags left out and the space around them dropped; nil when it holds no
    /// picture. `file`: the Markdown file's own address.
    nonisolated static func parts(of html: String, file: URL?) -> [Part]? {
        let tags = html.matches(of: imageTag)
        guard !tags.isEmpty else { return nil }
        var parts: [Part] = []
        var start = html.startIndex
        func addText(upTo end: String.Index) {
            let text = decoded(String(html[start..<end]).replacing(anyTag, with: " "))
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if !text.isEmpty { parts.append(.text(text)) }
        }
        for tag in tags {
            addText(upTo: tag.range.lowerBound)
            parts.append(.picture(picture(String(tag.output), file: file)))
            start = tag.range.upperBound
        }
        addText(upTo: html.endIndex)
        return parts
    }

    /// Whether the HTML centers what it holds (`align="center"`).
    nonisolated static func isCentered(_ html: String) -> Bool {
        html.contains(centered)
    }

    /// The pictures on the disk that `html` names.
    nonisolated static func files(in html: String, file: URL?) -> [URL] {
        (parts(of: html, file: file) ?? []).compactMap {
            if case .picture(let picture) = $0, let url = picture.url, url.isFileURL { url } else { nil }
        }
    }

    private nonisolated static func picture(_ tag: String, file: URL?) -> Picture {
        var values: [String: String] = [:]
        for match in tag.matches(of: attribute) {
            let value = match.output.2 ?? match.output.3 ?? match.output.4 ?? ""
            values[match.output.1.lowercased()] = decoded(String(value))
        }
        let source = values["src"] ?? ""
        let url =
            URL(string: source, relativeTo: file)
            ?? source.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed).flatMap {
                URL(string: $0, relativeTo: file)
            }
        // A size in pixels only: "50%" says nothing of points.
        func points(_ name: String) -> CGFloat? {
            values[name].flatMap { Double($0.hasSuffix("px") ? String($0.dropLast(2)) : $0) }.map { CGFloat($0) }
                .flatMap { $0 > 0 ? $0 : nil }
        }
        return Picture(
            url: source.isEmpty ? nil : url.map { $0.isFileURL ? $0.absoluteURL.standardizedFileURL : $0.absoluteURL },
            alt: values["alt"] ?? "", width: points("width"), height: points("height"))
    }

    /// The few entities written in a README's HTML.
    private nonisolated static func decoded(_ text: String) -> String {
        guard text.contains("&") else { return text }
        return text.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
    }
}
