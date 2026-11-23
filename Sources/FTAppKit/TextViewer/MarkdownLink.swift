import FTFoundation
import Foundation

/// Where a link clicked in Markdown's Preview leads. The Markdown is read with the file's own address as its base, so a
/// relative path is a file next to it, and `#name` one of its headings.
enum MarkdownLink: Equatable, Sendable {
    /// A place in the file shown: one of its headings, by the name GitHub gives it (`#getting-started`), or its top
    /// for nil (a link to the file itself).
    case heading(String?)
    /// A file or a folder on the disk, and the heading of the file to show, if the link names one.
    case disk(path: String, heading: String?)
    /// A web page, an email address, or anything else the system opens.
    case other(URL)

    /// What `link` leads to, the `.link` value of the Preview's text (a URL, or a string the text was given); nil for
    /// one that names nothing that can be opened. `shown`: the path of the file the Preview is drawn from.
    static func target(of link: Any, shown: String?) -> MarkdownLink? {
        let url: URL? =
            switch link {
            case let url as URL: url
            case let string as String: URL(string: string)
            default: nil
            }
        guard let url = url?.absoluteURL else { return nil }
        guard url.isFileURL else { return url.scheme == nil ? nil : .other(url) }
        // Its "." and ".." were resolved against the file's address; `standardizedFileURL` would also take
        // "/private" off the front, which names another path than the file's own.
        guard let path = DiskPath(urlSpelling: url)?.string, !path.isEmpty else { return nil }
        let heading = url.fragment(percentEncoded: false).flatMap { $0.isEmpty ? nil : $0 }
        if let shown, samePath(path, shown) { return .heading(heading) }
        return .disk(path: path, heading: heading)
    }

    /// The line of `markdown` (from 1) its heading named `name` starts on: the name GitHub gives a heading, its text in
    /// lowercase with spaces as hyphens and punctuation left out, a second heading of the same text named with "-1"
    /// after it, a third "-2". A name in another case finds it too. Nil when no heading has the name.
    static func headingLine(_ name: String, in markdown: String) -> Int? {
        let wanted = name.lowercased()
        return headings(in: markdown).first { $0.name == name || $0.name == wanted }?.line
    }

    /// Each heading of `markdown` in order: its name, as `headingLine` finds it by, and the line it starts on.
    static func headings(in markdown: String) -> [(name: String, line: Int)] {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false, interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible,
            appliesSourcePositionAttributes: true)
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else { return [] }
        // A heading's text is several runs when part of it is code, emphasized or a link.
        var found: [(identity: Int, text: String, line: Int)] = []
        for run in parsed.runs {
            guard
                let header = run.presentationIntent?.components.first(where: {
                    if case .header = $0.kind { true } else { false }
                })
            else { continue }
            let piece = String(parsed[run.range].characters)
            if let last = found.last, last.identity == header.identity {
                found[found.count - 1].text += piece
            } else {
                found.append((header.identity, piece, run.markdownSourcePosition?.startLine ?? 1))
            }
        }
        var used: [String: Int] = [:]
        return found.map { heading in
            let base = slug(heading.text)
            var name = base
            if let count = used[base] {
                name = "\(base)-\(count)"
                used[base] = count + 1
            } else {
                used[base] = 1
            }
            return (name, heading.line)
        }
    }

    /// A heading's text as GitHub names it: in lowercase, each space a hyphen, and only letters, numbers, marks,
    /// hyphens and underscores kept.
    static func slug(_ text: String) -> String {
        var name = String.UnicodeScalarView()
        for scalar in text.lowercased().unicodeScalars {
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                .decimalNumber, .letterNumber, .otherNumber, .nonspacingMark, .spacingMark, .enclosingMark,
                .connectorPunctuation:
                name.append(scalar)
            default:
                if scalar == " " || scalar == "-" { name.append("-") }
            }
        }
        return String(name)
    }
}
