// What a search keeps of the names (or paths) it walks past: Plain Text as the filters match names, a glob, or a
// regular expression. One is made for each search and asked from many threads at once.
import Darwin
import FTFoundation
import Foundation

/// Why a search's pattern can't be used.
public struct SearchPatternError: Error, Equatable, Sendable {
    public var message: String

    public static let invalid = SearchPatternError(message: "The pattern isn’t valid.")
    public static let tooSlow = SearchPatternError(
        message: "The pattern takes too long to match some names. Try a simpler one.")
    /// A name never holds a slash: the pattern is for paths.
    public static let slashInName = SearchPatternError(
        message:
            "No name has a “/” in it. To match the folders above a name too, choose Full Path in the search options.")
    /// A pattern that matches only names starting with a dot, while hidden items are left out.
    public static let onlyHidden = SearchPatternError(
        message: "Only hidden items have names that start with a dot. To find them, show them with View ▸ Hidden Files."
    )
}

/// How one name came out.
public enum SearchMatchOutcome: Equatable, Sendable {
    case match, noMatch
    /// A regular expression that took longer than `SearchNameMatch.timePerName` on one name.
    case tooSlow
}

public struct SearchNameMatch: @unchecked Sendable {
    private enum Test {
        case anything
        case text(NameTerms)
        /// One for each thread that asks: one shared by several makes them wait on each other.
        case expressions([NSRegularExpression])
    }

    private let test: Test
    /// Matched against the whole path rather than the name.
    public let fullPath: Bool
    /// For a glob, the longest run of plain text it requires, lowercased when it ignores case: an ASCII name without it
    /// is no match, told without the regular expression.
    private var required: [UInt8]?
    private var requiredIgnoresCase = false

    /// The longest one name may take to match a regular expression, in time on its thread. A pattern that takes
    /// longer (one that tries alternatives in turn, such as `(a+)+$`) ends the search rather than holding it.
    public static let timePerName: Double = 0.05

    /// `copies`: how many threads match at once, each with a regular expression of its own (`worker`).
    public init(_ request: SearchRequest, copies: Int = 1) throws(SearchPatternError) {
        let copies = max(1, copies)
        fullPath = request.matchScope == .path
        // Searches that would find nothing, said so rather than run.
        if !fullPath && Self.needsSlash(request.query, request.patternMode) { throw .slashInName }
        if !request.includeHidden && Self.needsLeadingDot(request.query, request.patternMode) { throw .onlyHidden }
        switch request.patternMode {
        case .text:
            // Text that folds to nothing finds everything, as an empty pattern does.
            test = NameTerms(request.query).map(Test.text) ?? .anything
        case .glob:
            guard !request.query.isEmpty else {
                test = .anything
                return
            }
            let pattern = try GlobPattern.regex(for: request.query)
            let ignoreCase = !SmartCase.globHasUppercase(request.query)
            test = .expressions(try Self.expressions(pattern, ignoreCase: ignoreCase, copies: copies))
            // A name is looked at without its folders, so not for the slash of a `**/` the glob starts with.
            let plain = fullPath ? request.query : String(Self.withoutLeadingFolders(request.query))
            required = GlobPattern.requiredText(plain).map {
                ignoreCase ? Array($0.lowercased().utf8) : Array($0.utf8)
            }
            requiredIgnoresCase = ignoreCase
        case .regex:
            guard !request.query.isEmpty else {
                test = .anything
                return
            }
            test = .expressions(
                try Self.expressions(
                    request.query, ignoreCase: !SmartCase.regexHasUppercase(request.query), copies: copies))
        }
    }

    /// Whether every name `query` finds has a "/" in it, which no name has. Only where the pattern leaves no doubt:
    /// a slash in a set (`[^./]`), beside a choice (`config|a/b`, `{a,b/c}`) or that may be absent (`a/?b`) is one
    /// the pattern can do without, and the search runs.
    static func needsSlash(_ query: String, _ mode: SearchPatternModePreference) -> Bool {
        guard query.contains("/") else { return false }
        switch mode {
        case .text:
            // Only a word the name must hold: one left out (`report !a/b`) leaves nothing out, and the rest is found.
            return NameTerms.words(query).contains { $0.contains("/") }
        case .regex:
            return !query.contains { "|[?*{\\".contains($0) }
        case .glob:
            guard !query.contains("{") else { return false }
            // `**/` at the start is any folders or none: what follows is matched against the name.
            let query = Self.withoutLeadingFolders(query)
            var inSet = false
            var previous: Character?
            var setStart = 0
            for (index, letter) in query.enumerated() {
                if inSet {
                    // A `]` right after the set opens (`[]`, `[!]`, `[^]`) is a letter of it.
                    let opening = index == setStart + 1 || (index == setStart + 2 && "!^".contains(previous ?? " "))
                    if letter == "]" && !opening { inSet = false }
                } else if letter == "[" {
                    inSet = true
                    setStart = index
                } else if letter == "/" {
                    return true
                }
                previous = letter
            }
            // A set never closed is letters as they are.
            return inSet
        }
    }

    /// A glob without the `**/` it starts with, however many.
    static func withoutLeadingFolders(_ glob: String) -> Substring {
        var rest = Substring(glob)
        while rest.hasPrefix("**/") { rest = rest.dropFirst(3) }
        return rest
    }

    /// Whether every name `query` finds starts with a dot, so that only hidden items have one. A regular expression
    /// whose dot may be absent (`^\.?config`) or is one side of a choice finds others too.
    static func needsLeadingDot(_ query: String, _ mode: SearchPatternModePreference) -> Bool {
        switch mode {
        case .text:
            return false
        case .glob:
            return query.hasPrefix(".")
        case .regex:
            guard query.hasPrefix("^\\."), !query.contains("|") else { return false }
            return !(query.dropFirst(3).first.map { "?*{".contains($0) } ?? false)
        }
    }

    private static func expressions(_ pattern: String, ignoreCase: Bool, copies: Int) throws(SearchPatternError)
        -> [NSRegularExpression]
    {
        do {
            return try (0..<copies).map { _ in
                try NSRegularExpression(pattern: pattern, options: ignoreCase ? [.caseInsensitive] : [])
            }
        } catch {
            throw .invalid
        }
    }

    /// Whether `subject` (the name, or the whole path for `fullPath`) is kept.
    public func outcome(_ subject: String) -> SearchMatchOutcome {
        switch test {
        case .anything:
            return .match
        case .text(let matcher):
            return matcher.matches(subject) ? .match : .noMatch
        case .expressions(let expressions):
            return Self.outcome(of: expressions[0], in: subject)
        }
    }

    public func matches(_ subject: String) -> Bool { outcome(subject) == .match }

    /// What one of the walk's threads keeps from one item to the next: the folder it is in, folded once for a Plain
    /// Text search of paths beyond ASCII. Each thread has its own, so nothing is shared.
    public final class Scratch: @unchecked Sendable {
        var folderBytes: [UInt8] = []
        /// The folder, folded for each word.
        var folders: [FoldedFolder]?

        public init() {}
    }

    /// Whether the item at `path` (its name from `nameOffset`) is kept. A Plain Text search of paths that go beyond
    /// ASCII folds each folder's path once, in `scratch`, rather than each item's whole path.
    public func outcome(
        path: UnsafeBufferPointer<UInt8>, nameOffset: Int, worker: Int, scratch: Scratch
    ) -> SearchMatchOutcome {
        guard fullPath else {
            let name = UnsafeBufferPointer(rebasing: path[nameOffset...])
            return outcome(bytes: name, worker: worker) { String(decoding: name, as: UTF8.self) }
        }
        guard case .text(let matcher) = test else {
            return outcome(bytes: path, worker: worker) { String(decoding: path, as: UTF8.self) }
        }
        if let fast = matcher.matches(asciiBytes: path) { return fast ? .match : .noMatch }
        // The folder is the path up to the slash before the name ("" for an item at the top of the disk).
        let folderBytes = UnsafeBufferPointer(rebasing: path[..<max(0, nameOffset - 1)])
        if scratch.folders == nil || !scratch.folderBytes.elementsEqual(folderBytes) {
            scratch.folderBytes = Array(folderBytes)
            let folder = String(decoding: folderBytes, as: UTF8.self)
            scratch.folders = matcher.allMatchers.map { FoldedFolder(folder, for: $0) }
        }
        guard let folders = scratch.folders else { return .noMatch }
        let name = String(decoding: UnsafeBufferPointer(rebasing: path[nameOffset...]), as: UTF8.self)
        return matcher.matches(name: name, in: folders) ? .match : .noMatch
    }

    /// Whether the subject given as its UTF-8 bytes is kept; `text` makes it a string, only when one is needed (a name
    /// beyond ASCII, or a pattern only a regular expression can tell).
    public func outcome(bytes: UnsafeBufferPointer<UInt8>, worker: Int = 0, text: () -> String) -> SearchMatchOutcome {
        switch test {
        case .anything:
            return .match
        case .text(let matcher):
            if let fast = matcher.matches(asciiBytes: bytes) { return fast ? .match : .noMatch }
            return matcher.matches(text()) ? .match : .noMatch
        case .expressions(let expressions):
            if let required, Self.isASCII(bytes), !Self.contains(bytes, required, ignoringCase: requiredIgnoresCase) {
                return .noMatch
            }
            return Self.outcome(of: expressions[worker % expressions.count], in: text())
        }
    }

    private static func isASCII(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        for byte in bytes where byte >= 0x80 { return false }
        return true
    }

    /// Whether `bytes` hold `needle`, ASCII letters compared case aside when asked (`needle` is lowercased then).
    private static func contains(_ bytes: UnsafeBufferPointer<UInt8>, _ needle: [UInt8], ignoringCase: Bool) -> Bool {
        let count = needle.count
        guard count <= bytes.count else { return false }
        return needle.withUnsafeBufferPointer { needle in
            var start = 0
            while start <= bytes.count - count {
                var offset = 0
                while offset < count {
                    var byte = bytes[start + offset]
                    if ignoringCase && byte >= 65 && byte <= 90 { byte += 32 }
                    if byte != needle[offset] { break }
                    offset += 1
                }
                if offset == count { return true }
                start += 1
            }
            return false
        }
    }

    /// How often a match reports its progress before its time is looked at: an ordinary name never comes near it, so
    /// it is matched without asking the clock, which costs as much as matching it.
    static let progressBeforeTiming = 256

    /// The first match is all that is asked. A match that runs on is looked in on (`reportProgress`), and given up past
    /// `timePerName` of its thread's time.
    private static func outcome(of expression: NSRegularExpression, in subject: String) -> SearchMatchOutcome {
        let range = NSRange(location: 0, length: subject.utf16.count)
        var found = false
        var tooSlow = false
        var reports = 0
        var started: UInt64 = 0
        expression.enumerateMatches(in: subject, options: [.reportProgress], range: range) { result, _, stop in
            if result != nil {
                found = true
                stop.pointee = true
                return
            }
            reports += 1
            guard reports % progressBeforeTiming == 0 else { return }
            let now = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            if started == 0 {
                started = now
            } else if Double(now - started) / 1e9 > timePerName {
                tooSlow = true
                stop.pointee = true
            }
        }
        return found ? .match : tooSlow ? .tooSlow : .noMatch
    }
}

/// Glob and Regex match case only when the pattern has a capital letter: "report" finds "Report", "Report"
/// only itself.
public enum SmartCase {
    /// A capital in the pattern's own letters: what follows a backslash is an escape (`\S`, `\W`, `\p{Lu}`), not a
    /// letter of a name, and doesn't count.
    public static func regexHasUppercase(_ pattern: String) -> Bool {
        var scalars = pattern.unicodeScalars.makeIterator()
        while let scalar = scalars.next() {
            if scalar == "\\" {
                guard let escaped = scalars.next() else { break }
                // \p{…}, \P{…}, \x{…}, \N{…}: the braces' contents are a name or a number.
                if "pPxN".unicodeScalars.contains(escaped) {
                    var copy = scalars
                    if copy.next() == "{" {
                        while let inside = scalars.next(), inside != "}" {}
                    }
                }
                continue
            }
            if scalar.properties.isUppercase { return true }
        }
        return false
    }

    /// A capital anywhere in the glob, escaped or not: in a glob an escaped letter is that letter.
    public static func globHasUppercase(_ pattern: String) -> Bool {
        pattern.unicodeScalars.contains { $0.properties.isUppercase }
    }
}

/// A glob as a regular expression that matches the whole name, or the whole path: `*` any run of characters but `/`,
/// `?` one character but `/`, `[abc]`, `[a-z]` and `[!abc]` (or `[^abc]`) one of a set, `{a,b}` either, `**` any
/// number of folders when it stands between slashes or at an end, and `\` the next character as itself.
public enum GlobPattern {
    public static func regex(for glob: String) throws(SearchPatternError) -> String {
        var reader = Reader(Array(glob.unicodeScalars))
        return "^" + (try reader.sequence(inBraces: false)) + "$"
    }

    /// The longest run of plain characters every match of `glob` holds, when it is ASCII and the glob has no `{…}`
    /// (whose alternatives make any text optional): ".dylib" for "*.dylib". Nil when there is none worth looking for.
    public static func requiredText(_ glob: String) -> String? {
        guard !glob.contains("{") else { return nil }
        var best = ""
        var run = ""
        var scalars = glob.unicodeScalars.makeIterator()
        var inSet = false
        while let scalar = scalars.next() {
            if inSet {
                if scalar == "]" { inSet = false }
                continue
            }
            switch scalar {
            case "*", "?":
                run = ""
            case "[":
                run = ""
                inSet = true
                // A "]" first in the set, or first after the "!" or "^" that turns the set round, is one of its
                // members and doesn't end it.
                var copy = scalars
                if let next = copy.next(), next == "!" || next == "^" { _ = scalars.next() }
                copy = scalars
                if let next = copy.next(), next == "]" { _ = scalars.next() }
            case "\\":
                if let escaped = scalars.next() { run.unicodeScalars.append(escaped) }
            default:
                run.unicodeScalars.append(scalar)
            }
            if run.unicodeScalars.count > best.unicodeScalars.count { best = run }
        }
        guard !best.isEmpty, best.unicodeScalars.allSatisfy(\.isASCII) else { return nil }
        return best
    }

    private struct Reader {
        let scalars: [Unicode.Scalar]
        var at = 0

        init(_ scalars: [Unicode.Scalar]) { self.scalars = scalars }

        private func peek(_ offset: Int = 0) -> Unicode.Scalar? {
            scalars.indices.contains(at + offset) ? scalars[at + offset] : nil
        }

        /// Until the end, or inside `{…}` until the `,` or `}` that ends an alternative.
        mutating func sequence(inBraces: Bool) throws(SearchPatternError) -> String {
            var out = ""
            while let scalar = peek() {
                if inBraces && (scalar == "," || scalar == "}") { return out }
                switch scalar {
                case "\\":
                    guard let escaped = peek(1) else { throw .invalid }
                    out += literal(escaped)
                    at += 2
                case "*":
                    out += stars()
                case "?":
                    out += "[^/]"
                    at += 1
                case "[":
                    out += try set()
                case "{":
                    out += try alternatives()
                default:
                    out += literal(scalar)
                    at += 1
                }
            }
            if inBraces { throw .invalid }
            return out
        }

        /// `*`, or `**` as folders at a slash or an end.
        private mutating func stars() -> String {
            guard peek(1) == "*" else {
                at += 1
                return "[^/]*"
            }
            let before = at == 0 ? nil : scalars[at - 1]
            var end = at
            while end < scalars.count, scalars[end] == "*" { end += 1 }
            let after = end < scalars.count ? scalars[end] : nil
            let startsPart = before == nil || before == "/"
            let endsPart = after == nil || after == "/"
            at = end
            guard startsPart && endsPart else { return "[^/]*" }
            switch (before, after) {
            case (nil, nil):
                return ".*"
            case (nil, _):
                // "**/x": x in any folder, the top one too.
                at += 1
                return "(?:.*/)?"
            case (_, nil):
                // "x/**": anything inside x.
                return ".*"
            default:
                // "a/**/b": b in a, or in any folder inside it.
                at += 1
                return "(?:.*/)?"
            }
        }

        /// `[…]`: `]` first is a member, `!` or `^` first makes it the set of everything else but `/`.
        private mutating func set() throws(SearchPatternError) -> String {
            var index = at + 1
            var negated = false
            if index < scalars.count, scalars[index] == "!" || scalars[index] == "^" {
                negated = true
                index += 1
            }
            var members = ""
            var first = true
            while true {
                guard index < scalars.count else { throw .invalid }
                let scalar = scalars[index]
                if scalar == "]" && !first { break }
                first = false
                if scalar == "-", index + 1 < scalars.count, scalars[index + 1] != "]", !members.isEmpty {
                    members += "-"
                } else {
                    members += setMember(scalar)
                }
                index += 1
            }
            at = index + 1
            return negated ? "[^/" + members + "]" : "[" + members + "]"
        }

        /// `{a,b}`: any of the alternatives, each a glob of its own.
        private mutating func alternatives() throws(SearchPatternError) -> String {
            at += 1
            var choices: [String] = []
            while true {
                choices.append(try sequence(inBraces: true))
                guard let scalar = peek() else { throw .invalid }
                at += 1
                if scalar == "}" { break }
            }
            return "(?:" + choices.joined(separator: "|") + ")"
        }

        /// A character as itself; a slash, which means nothing in a regular expression, as it is.
        private func literal(_ scalar: Unicode.Scalar) -> String {
            scalar == "/" ? "/" : NSRegularExpression.escapedPattern(for: String(scalar))
        }

        /// A member of a set as ICU reads one: its own punctuation escaped.
        private func setMember(_ scalar: Unicode.Scalar) -> String {
            "\\[]^-&{}$:".unicodeScalars.contains(scalar) ? "\\" + String(scalar) : String(scalar)
        }
    }
}
