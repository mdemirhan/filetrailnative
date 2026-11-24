import Foundation

// The formats people write documents in, besides Markdown: reStructuredText, AsciiDoc, Org and Typst. Each colors its
// headings, its markup and its blocks, and a block of code that names its language is colored as that language.

private let schemeEnd = Array("://".utf16)
private let schemes: Set<String> = ["http", "https", "ftp", "file"]
private let doubleSlash = Array("//".utf16)
private let doctest = Array(">>>".utf16)
private let restAdornments = Set("=-`:'\"~^_*+#<>.".utf16)
private let asciiDocDelimiters = Set("-./+=*_".utf16)
private let orgPriority = Array("[#".utf16)
private let orgTermSeparator = Array(" :: ".utf16)
private let orgFootnote = Array("fn:".utf16)
private let restCodeDirectives: Set<String> = ["code", "code-block", "sourcecode"]
private let restComment: UInt16 = 0
private let restLiteral: UInt16 = 1
private let restCode: UInt16 = 2

private let asciiDocAdmonitions: Set<String> = ["NOTE", "TIP", "IMPORTANT", "WARNING", "CAUTION"]
private let asciiDocLinkMacros: Set<String> = ["link", "xref", "mailto", "image", "http", "https", "ftp", "irc"]
private let asciiDocCodeMacros: Set<String> = ["kbd", "btn", "menu", "pass", "stem", "latexmath", "asciimath"]

/// Org's blocks whose text isn't Org, by `LexState.rule`.
private let orgBlocks = ["src", "example", "comment", "export"]
private let orgTodo: Set<String> = ["TODO", "DONE", "NEXT", "WAITING", "HOLD", "CANCELLED", "CANCELED"]
private let orgPlanning: Set<String> = ["SCHEDULED", "DEADLINE", "CLOSED"]
/// What may come before an Org emphasis mark: `*bold*` after a space, an opening bracket or a quote.
private let orgPreEmphasis: Set<UInt16> = [
    Char.space, Char.tab, Char.minus, Char.openParen, Char.openBrace, Char.apostrophe, Char.quote,
]

private let typstRaw: UInt16 = 0
private let typstCodeBlock: UInt16 = 1
private let typstComment = CommentRule("/*", "*/", nested: true)
private let typstStatements: Set<String> = [
    "let", "set", "show", "import", "include", "if", "for", "while", "return", "context",
]
private let typstCode: CodeRules = {
    var rules = CodeRules()
    rules.lineComments = [Array("//".utf16)]
    rules.blockComments = [typstComment]
    rules.strings = [StringRule("\"")]
    rules.keywords = TextLanguages.words(
        "let set show import include if else for in while return break continue context as not and or")
    rules.literals = TextLanguages.words("none auto true false")
    rules.identifierExtras = [Char.minus]
    return rules
}()

extension Line {
    // MARK: Shared

    /// The end of a run of `c` starting at `i`.
    func runEnd(of c: UInt16, from i: Int) -> Int {
        var j = i
        while j < count && chars[j] == c { j += 1 }
        return j
    }

    /// Whether the line from `i` is a run of one character and spaces after it, and how long the run is.
    func soleRun(from i: Int) -> (mark: UInt16, length: Int)? {
        guard i < count else { return nil }
        let end = runEnd(of: chars[i], from: i)
        return firstNonSpace(from: end) == count ? (chars[i], end - i) : nil
    }

    /// `1.` or `3)` and a space at `i`: the end of the marker.
    func orderedMarkerEnd(from i: Int) -> Int? {
        var j = i
        while j < count && Char.isDigit(chars[j]) { j += 1 }
        guard j > i, at(j) == Char.dot || at(j) == Char.closeParen, Char.isSpace(at(j + 1)) || j + 1 == count else {
            return nil
        }
        return j + 1
    }

    /// A web address at `i`, `https://…` to the next space or closing bracket; its end, or nil when there is none.
    func urlEnd(from i: Int) -> Int? {
        let end = identifierEnd(from: i)
        guard matches(schemeEnd, at: end), schemes.contains(word(i, end)) else { return nil }
        var j = end + 3
        while j < count && !Char.isSpace(chars[j]) && chars[j] != Char.greater && chars[j] != Char.closeBracket {
            j += 1
        }
        return j
    }

    /// Lexes `chars[start..<end]` with code rules, as one line, its runs put at their place in this one.
    mutating func lexCodeSegment(_ rules: CodeRules, _ start: Int, _ end: Int) -> [SyntaxToken] {
        var inner = Line(
            chars: UnsafeBufferPointer(rebasing: chars[start..<max(start, end)]), tokens: [], embeds: false)
        _ = inner.lexCode(rules, .normal)
        return inner.tokens
    }

    /// The text of a block of code: as the language its state names, or as code when it names none.
    mutating func lexBlockText(_ start: Int, _ end: Int, _ state: LexState) -> LexState {
        if state.embedded != 0 { return lexEmbedded(start, end, state) }
        emit(start, end, .code)
        return state
    }

    // MARK: reStructuredText

    /// A section's title is known only by the line under it, which a line at a time can't look ahead to: the line
    /// under it and one over it are colored, the title isn't.
    mutating func lexReST(_ start: LexState) -> LexState {
        let indent = firstNonSpace()
        // A comment, a literal block and a code block go on over blank lines and lines indented past where they start.
        if start.mode == .block && (indent == count || indent > Int(start.depth)) {
            switch start.rule {
            case restComment:
                emit(indent, count, .comment)
                return start
            case restCode where at(indent) == Char.colon && restFieldEnd(from: indent) != nil:
                emit(indent, restFieldEnd(from: indent) ?? count, .property)
                return start
            default:
                return lexBlockText(indent, count, start)
            }
        }
        guard indent < count else { return .normal }
        let c = chars[indent]
        if indent == 0, let run = soleRun(from: 0), run.length >= 2, isRestAdornment(run.mark) {
            emit(0, count, .heading)
            return .normal
        }
        if c == Char.dot && at(indent + 1) == Char.dot && (indent + 2 == count || Char.isSpace(at(indent + 2))) {
            return lexRestExplicit(indent)
        }
        if matches(doctest, at: indent) {
            emit(indent, count, .code)
            return .normal
        }
        var i = indent
        if c == Char.colon, let end = restFieldEnd(from: indent) {
            emit(indent, end, .property)
            i = end
        } else if let end = restListMarkerEnd(from: indent) {
            emit(indent, end, .keyword)
            i = end
        }
        lexRestInline(from: i)
        var end = count
        while end > i && Char.isSpace(chars[end - 1]) { end -= 1 }
        if end >= 2 && chars[end - 1] == Char.colon && chars[end - 2] == Char.colon {
            // A paragraph that ends in `::` is followed by a literal block.
            return LexState(.block, rule: restLiteral, depth: UInt16(indent))
        }
        return .normal
    }

    func isRestAdornment(_ c: UInt16) -> Bool { restAdornments.contains(c) }

    /// `:name:` and a space or the line's end: the end of the field's name.
    func restFieldEnd(from i: Int) -> Int? {
        var j = i + 1
        while j < count {
            if chars[j] == Char.colon && j > i + 1 && (j + 1 == count || Char.isSpace(chars[j + 1])) { return j + 1 }
            if chars[j] == Char.backtick { return nil }
            j += 1
        }
        return nil
    }

    func restListMarkerEnd(from i: Int) -> Int? {
        let c = chars[i]
        if (c == Char.minus || c == Char.star || c == Char.plus || c == 0x2022) && (Char.isSpace(at(i + 1))) {
            return i + 1
        }
        if c == Char.hash && at(i + 1) == Char.dot && Char.isSpace(at(i + 2)) { return i + 2 }
        return orderedMarkerEnd(from: i)
    }

    /// A line starting `..`: a directive, a link's target, a footnote, a substitution or else a comment.
    mutating func lexRestExplicit(_ indent: Int) -> LexState {
        let body = firstNonSpace(from: indent + 2)
        guard body < count else {
            emit(indent, count, .comment)
            return LexState(.block, rule: restComment, depth: UInt16(indent))
        }
        if chars[body] == Char.underscore {
            emit(indent, count, .link)
            return .normal
        }
        if chars[body] == Char.openBracket, let close = find([Char.closeBracket], from: body + 1) {
            emit(indent, close, .meta)
            lexRestInline(from: close)
            return .normal
        }
        var i = body
        if chars[body] == Char.pipe, let close = find([Char.pipe], from: body + 1) {
            emit(indent, indent + 2, .keyword)
            emit(body, close, .variable)
            i = firstNonSpace(from: close)
        }
        var j = i
        while j < count && !Char.isSpace(chars[j]) && !(chars[j] == Char.colon && at(j + 1) == Char.colon) { j += 1 }
        guard j > i, at(j) == Char.colon else {
            emit(indent, count, .comment)
            return LexState(.block, rule: restComment, depth: UInt16(indent))
        }
        emit(i == body ? indent : i, j + 2, .keyword)
        lexRestInline(from: j + 2)
        if restCodeDirectives.contains(word(i, j).lowercased()) {
            return LexState(.block, rule: restCode, depth: UInt16(indent), embedded: fenceLanguage(from: j + 2))
        }
        return .normal
    }

    mutating func lexRestInline(from start: Int) {
        var i = start
        while i < count {
            let c = chars[i]
            if c == Char.backslash {
                i += 2
                continue
            }
            let opens = (i == 0 || !Char.isIdentPart(chars[i - 1])) && !Char.isSpace(at(i + 1)) && i + 1 < count
            if c == Char.backtick && at(i + 1) == Char.backtick,
                let end = find([Char.backtick, Char.backtick], from: i + 2)
            {
                emit(i, end, .code)
                i = end
                continue
            }
            if c == Char.backtick && opens, let close = find([Char.backtick], from: i + 1) {
                // `text`_ and `text <address>`_ are links; `text` alone is interpreted text.
                let end = runEnd(of: Char.underscore, from: close)
                emit(i, end, end > close ? .link : .emphasis)
                i = end
                continue
            }
            if c == Char.star && at(i + 1) == Char.star, let end = find([Char.star, Char.star], from: i + 2) {
                emit(i, end, .strong)
                i = end
                continue
            }
            if c == Char.star && opens, let end = find([Char.star], from: i + 1) {
                emit(i, end, .emphasis)
                i = end
                continue
            }
            if c == Char.colon && opens, let role = restRole(from: i) {
                emit(i, role.name, .attribute)
                emit(role.name, role.end, .code)
                i = role.end
                continue
            }
            if c == Char.pipe && opens, let end = find([Char.pipe], from: i + 1) {
                emit(i, runEnd(of: Char.underscore, from: end), .variable)
                i = end
                continue
            }
            if c == Char.openBracket, let close = find([Char.closeBracket, Char.underscore], from: i + 1),
                !word(i, close).contains(" ")
            {
                emit(i, close, .meta)
                i = close
                continue
            }
            if Char.isIdentStart(c) {
                if let end = urlEnd(from: i) {
                    emit(i, end, .link)
                    i = end
                    continue
                }
                let end = identifierEnd(from: i)
                // `name_` is a reference to a target of that name.
                if end - i > 1 && chars[end - 1] == Char.underscore && chars[end - 2] != Char.underscore
                    || end - i > 2 && chars[end - 1] == Char.underscore && chars[end - 2] == Char.underscore
                {
                    emit(i, end, .link)
                }
                i = end
                continue
            }
            i += 1
        }
    }

    /// `:role:` then `` `text` ``: where the role ends and where its text does.
    func restRole(from i: Int) -> (name: Int, end: Int)? {
        var j = i + 1
        while j < count
            && (Char.isIdentPart(chars[j]) || chars[j] == Char.minus || chars[j] == Char.dot
                || (chars[j] == Char.colon && at(j + 1) != Char.backtick))
        {
            j += 1
        }
        guard j > i + 1, at(j) == Char.colon, at(j + 1) == Char.backtick,
            let end = find([Char.backtick], from: j + 2)
        else { return nil }
        return (j + 1, end)
    }

    // MARK: AsciiDoc

    /// A delimited block's state is its delimiter's character and length, and the language a `[source,…]` line before
    /// it named; a `[source,…]` line leaves its language for the next line in an otherwise normal state.
    mutating func lexAsciiDoc(_ start: LexState) -> LexState {
        if start.mode == .block {
            if let run = soleRun(from: 0), run.mark == UInt16(start.rule),
                run.mark == Char.backtick ? run.length >= Int(start.depth) : run.length == Int(start.depth)
            {
                emit(0, count, .meta)
                return .normal
            }
            if start.rule == Char.slash {
                emit(0, count, .comment)
                return start
            }
            return lexBlockText(0, count, start)
        }
        guard count > 0 else { return .normal }
        let c = chars[0]
        if let run = soleRun(from: 0),
            (run.length >= 4 && asciiDocDelimiters.contains(run.mark))
                || (run.mark == Char.minus && run.length == 2)
        {
            emit(0, count, .meta)
            switch run.mark {
            case Char.slash, Char.dot, Char.plus:
                return LexState(.block, rule: run.mark, depth: UInt16(run.length))
            case Char.minus where run.length >= 4:
                return LexState(.block, rule: run.mark, depth: UInt16(run.length), embedded: start.embedded)
            default:
                return .normal
            }
        }
        if c == Char.backtick && runEnd(of: c, from: 0) >= 3 {
            let marks = runEnd(of: c, from: 0)
            emit(0, count, .code)
            let named = fenceLanguage(from: marks)
            return LexState(.block, rule: c, depth: UInt16(marks), embedded: named == 0 ? start.embedded : named)
        }
        if matches(doubleSlash, at: 0) {
            emit(0, count, .comment)
            return .normal
        }
        if c == Char.equals || c == Char.hash {
            let end = runEnd(of: c, from: 0)
            if end <= 6 && Char.isSpace(at(end)) {
                emit(0, count, .heading)
                return .normal
            }
        }
        if c == Char.colon {
            var j = 1
            while j < count && chars[j] != Char.colon && !Char.isSpace(chars[j]) { j += 1 }
            if at(j) == Char.colon && j > 1 {
                emit(0, j + 1, .property)
                lexAsciiDocInline(from: j + 1)
                return .normal
            }
        }
        var last = count
        while last > 0 && Char.isSpace(chars[last - 1]) { last -= 1 }
        guard last > 0 else { return .normal }
        if c == Char.openBracket && chars[last - 1] == Char.closeBracket {
            emit(0, last, .attribute)
            return LexState(.normal, embedded: asciiDocSourceLanguage(last - 1))
        }
        if c == Char.dot && !Char.isSpace(at(1)) && at(1) != Char.dot && count > 1 {
            emit(0, count, .heading)
            return LexState(.normal, embedded: start.embedded)
        }
        let indent = firstNonSpace()
        var i = indent
        if let end = asciiDocListMarkerEnd(from: indent) {
            emit(indent, end, .keyword)
            i = end
        } else if indent > 0 {
            // A paragraph that starts with a space is literal.
            emit(indent, count, .code)
            return .normal
        } else if let end = asciiDocMacroEnd() {
            i = end
        }
        let wordEnd = identifierEnd(from: i)
        if at(wordEnd) == Char.colon && Char.isSpace(at(wordEnd + 1)) && asciiDocAdmonitions.contains(word(i, wordEnd))
        {
            emit(i, wordEnd + 1, .keyword)
            i = wordEnd + 1
        } else if let term = asciiDocTermEnd(from: i) {
            emit(i, term, .property)
            i = term
        }
        lexAsciiDocInline(from: i)
        if chars[last - 1] == Char.plus && (last == 1 || Char.isSpace(chars[last - 2])) { emit(last - 1, last, .meta) }
        return .normal
    }

    /// `[source,python]`'s language, as its place for a `LexState`; 0 for an attribute line of another kind.
    func asciiDocSourceLanguage(_ close: Int) -> UInt16 {
        guard close > 1, embeds else { return 0 }
        let parts = word(1, close).split(separator: ",", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard parts.count >= 2, parts[0] == "source" || parts[0].isEmpty, !parts[1].contains("=") else { return 0 }
        return TextLanguages.position(named: parts[1])
    }

    func asciiDocListMarkerEnd(from i: Int) -> Int? {
        guard i < count else { return nil }
        let c = chars[i]
        if c == Char.star || c == Char.dot {
            let end = runEnd(of: c, from: i)
            if Char.isSpace(at(end)) { return end }
        }
        if c == Char.minus && Char.isSpace(at(i + 1)) { return i + 1 }
        return orderedMarkerEnd(from: i)
    }

    /// `image::path[alt]` at the line's start: its name and target colored, and where its attributes start.
    mutating func asciiDocMacroEnd() -> Int? {
        let nameEnd = identifierEnd(from: 0)
        guard nameEnd > 0, matches(Array("::".utf16), at: nameEnd), !Char.isSpace(at(nameEnd + 2)),
            nameEnd + 2 < count
        else { return nil }
        emit(0, nameEnd + 2, .keyword)
        var j = nameEnd + 2
        while j < count && chars[j] != Char.openBracket { j += 1 }
        emit(nameEnd + 2, j, .link)
        emit(j, count, .attribute)
        return count
    }

    /// `term::` and a space or the line's end, as a description list has: where the term ends.
    func asciiDocTermEnd(from i: Int) -> Int? {
        var j = i
        while j + 1 < count {
            if chars[j] == Char.colon && chars[j + 1] == Char.colon {
                let end = runEnd(of: Char.colon, from: j)
                return j > i && (end == count || Char.isSpace(chars[end])) ? end : nil
            }
            j += 1
        }
        return nil
    }

    mutating func lexAsciiDocInline(from start: Int) {
        var i = start
        while i < count {
            let c = chars[i]
            if c == Char.backslash {
                i += 2
                continue
            }
            let opens = (i == 0 || !Char.isIdentPart(chars[i - 1])) && !Char.isSpace(at(i + 1)) && i + 1 < count
            if c == Char.backtick && opens, let end = find([Char.backtick], from: i + 1) {
                emit(i, end, .code)
                i = end
                continue
            }
            if (c == Char.star || c == Char.underscore) && at(i + 1) == c, let end = find([c, c], from: i + 2) {
                emit(i, end, c == Char.star ? .strong : .emphasis)
                i = end
                continue
            }
            if (c == Char.star || c == Char.underscore) && opens, let end = find([c], from: i + 1) {
                emit(i, end, c == Char.star ? .strong : .emphasis)
                i = end
                continue
            }
            if c == Char.openBrace && Char.isIdentStart(at(i + 1)) {
                let end = identifierEnd(from: i + 1, extra: [Char.minus])
                if at(end) == Char.closeBrace {
                    emit(i, end + 1, .variable)
                    i = end + 1
                    continue
                }
            }
            if c == Char.less && at(i + 1) == Char.less, let end = find([Char.greater, Char.greater], from: i + 2) {
                emit(i, end, .link)
                i = end
                continue
            }
            if Char.isIdentStart(c) {
                let end = identifierEnd(from: i)
                if let macro = asciiDocInlineMacroEnd(from: i, nameEnd: end) {
                    i = macro
                    continue
                }
                i = end
                continue
            }
            i += 1
        }
    }

    /// `link:url[text]`, `https://…[text]`, `footnote:[text]`, `kbd:[⌘C]`: colored, and their end.
    mutating func asciiDocInlineMacroEnd(from i: Int, nameEnd: Int) -> Int? {
        guard at(nameEnd) == Char.colon, i == 0 || !Char.isIdentPart(chars[i - 1]) else { return nil }
        let name = word(i, nameEnd)
        var j = nameEnd + 1
        while j < count && !Char.isSpace(chars[j]) && chars[j] != Char.openBracket { j += 1 }
        var end = j
        if at(j) == Char.openBracket, let close = find([Char.closeBracket], from: j + 1) { end = close }
        if asciiDocLinkMacros.contains(name) {
            guard end > nameEnd + 1 else { return nil }
            emit(i, end, .link)
        } else if name == "footnote" && at(nameEnd + 1) == Char.openBracket {
            emit(i, end, .meta)
        } else if asciiDocCodeMacros.contains(name) && at(nameEnd + 1) == Char.openBracket {
            emit(i, end, .code)
        } else {
            return nil
        }
        return end
    }

    // MARK: Org

    mutating func lexOrg(_ start: LexState) -> LexState {
        let indent = firstNonSpace()
        if start.mode == .block {
            if orgBlockMark(at: indent) == "end_\(orgBlocks[Int(start.rule)])" {
                emit(indent, count, .keyword)
                return .normal
            }
            if orgBlocks[Int(start.rule)] == "comment" {
                emit(0, count, .comment)
                return start
            }
            return lexBlockText(0, count, start)
        }
        guard indent < count else { return .normal }
        let c = chars[indent]
        if indent == 0 && c == Char.star {
            let stars = runEnd(of: Char.star, from: 0)
            if stars == count || Char.isSpace(chars[stars]) {
                lexOrgHeading(stars)
                return .normal
            }
        }
        if c == Char.hash && at(indent + 1) == Char.plus {
            return lexOrgKeywordLine(indent)
        }
        if c == Char.hash && (indent + 1 == count || Char.isSpace(at(indent + 1))) {
            emit(indent, count, .comment)
            return .normal
        }
        if c == Char.colon {
            if indent + 1 == count || Char.isSpace(at(indent + 1)) {
                emit(indent, count, .code)
                return .normal
            }
            var j = indent + 1
            while j < count && (Char.isIdentPart(chars[j]) || chars[j] == Char.minus || chars[j] == Char.plus) {
                j += 1
            }
            if at(j) == Char.colon && j > indent + 1 {
                let isDrawer = firstNonSpace(from: j + 1) == count
                emit(indent, j + 1, isDrawer ? .attribute : .property)
                lexOrgInline(from: j + 1)
                return .normal
            }
        }
        if let run = soleRun(from: indent), run.mark == Char.minus, run.length >= 5 {
            emit(indent, count, .meta)
            return .normal
        }
        if c == Char.pipe && at(indent + 1) == Char.minus {
            emit(indent, count, .meta)
            return .normal
        }
        var i = indent
        if ((c == Char.minus || c == Char.plus || (c == Char.star && indent > 0)) && Char.isSpace(at(indent + 1)))
            || orderedMarkerEnd(from: indent) != nil
        {
            let marker = orderedMarkerEnd(from: indent) ?? indent + 1
            emit(indent, marker, .keyword)
            i = firstNonSpace(from: marker)
            if at(i) == Char.openBracket && at(i + 2) == Char.closeBracket {
                emit(i, i + 3, .keyword)
                i += 3
            }
            if let term = find(orgTermSeparator, from: i) {
                emit(i, term - 1, .property)
                i = term
            }
        }
        lexOrgInline(from: i)
        return .normal
    }

    /// `#+begin_src` and the like, lowercased, at `i`; nil for a line that isn't one.
    func orgBlockMark(at i: Int) -> String? {
        guard at(i) == Char.hash && at(i + 1) == Char.plus else { return nil }
        return word(i + 2, identifierEnd(from: i + 2)).lowercased()
    }

    /// Stars, a TODO keyword, a priority, the title and its tags.
    mutating func lexOrgHeading(_ stars: Int) {
        var i = firstNonSpace(from: stars)
        emit(0, i, .heading)
        let wordEnd = identifierEnd(from: i)
        if orgTodo.contains(word(i, wordEnd)) {
            emit(i, wordEnd, .keyword)
            i = wordEnd
        }
        let priority = firstNonSpace(from: i)
        if matches(orgPriority, at: priority) && at(priority + 3) == Char.closeBracket {
            emit(i, priority, .heading)
            emit(priority, priority + 4, .keyword)
            i = priority + 4
        }
        var end = count
        while end > i && Char.isSpace(chars[end - 1]) { end -= 1 }
        var tags = end
        if end > i && chars[end - 1] == Char.colon {
            var j = end - 1
            while j > i
                && (Char.isIdentPart(chars[j - 1])
                    || [Char.colon, Char.at, Char.hash, Char.percent].contains(chars[j - 1]))
            {
                j -= 1
            }
            if j > i && chars[j] == Char.colon && Char.isSpace(chars[j - 1]) && end - j > 2 { tags = j }
        }
        emit(i, tags, .heading)
        emit(tags, end, .attribute)
    }

    /// `#+title: …`, `#+begin_src python`, `#+end_quote`.
    mutating func lexOrgKeywordLine(_ indent: Int) -> LexState {
        let keyEnd = identifierEnd(from: indent + 2, extra: [Char.minus])
        let key = word(indent + 2, keyEnd).lowercased()
        if key.hasPrefix("begin_") || key.hasPrefix("end_") {
            emit(indent, keyEnd, .keyword)
            emit(keyEnd, count, .meta)
            if key.hasPrefix("begin_"), let rule = orgBlocks.firstIndex(of: String(key.dropFirst(6))) {
                let named = rule == 0 ? fenceLanguage(from: keyEnd) : 0
                return LexState(.block, rule: UInt16(rule), embedded: named)
            }
            return .normal
        }
        let colon = at(keyEnd) == Char.colon ? keyEnd + 1 : keyEnd
        emit(indent, colon, .keyword)
        lexOrgInline(from: colon)
        return .normal
    }

    mutating func lexOrgInline(from start: Int) {
        var i = start
        while i < count {
            let c = chars[i]
            if [Char.star, Char.slash, Char.underscore, Char.equals, Char.tilde, Char.plus].contains(c),
                i == 0 || orgPreEmphasis.contains(chars[i - 1]), !Char.isSpace(at(i + 1)), i + 1 < count,
                let end = orgEmphasisEnd(c, from: i + 2)
            {
                switch c {
                case Char.star: emit(i, end, .strong)
                case Char.slash, Char.underscore: emit(i, end, .emphasis)
                case Char.equals, Char.tilde: emit(i, end, .code)
                default: break
                }
                i = end
                continue
            }
            if c == Char.openBracket && at(i + 1) == Char.openBracket,
                let end = find([Char.closeBracket, Char.closeBracket], from: i + 2)
            {
                emit(i, end, .link)
                i = end
                continue
            }
            if c == Char.openBracket && matches(orgFootnote, at: i + 1),
                let end = find([Char.closeBracket], from: i + 1)
            {
                emit(i, end, .meta)
                i = end
                continue
            }
            if (c == Char.less || c == Char.openBracket) && Char.isDigit(at(i + 1)) && at(i + 5) == Char.minus,
                let end = find([c == Char.less ? Char.greater : Char.closeBracket], from: i + 1)
            {
                emit(i, end, .number)
                i = end
                continue
            }
            if Char.isIdentStart(c) {
                if let end = urlEnd(from: i) {
                    emit(i, end, .link)
                    i = end
                    continue
                }
                let end = identifierEnd(from: i)
                if at(end) == Char.colon && orgPlanning.contains(word(i, end)) { emit(i, end + 1, .keyword) }
                i = end
                continue
            }
            i += 1
        }
    }

    /// The end of Org emphasis whose mark is `c`, its text starting before `i`: a mark after text, then a space, the
    /// line's end or punctuation.
    func orgEmphasisEnd(_ c: UInt16, from i: Int) -> Int? {
        var k = i
        while k < count {
            if chars[k] == c && !Char.isSpace(chars[k - 1]) && (k + 1 == count || !Char.isIdentPart(chars[k + 1])) {
                return k + 1
            }
            k += 1
        }
        return nil
    }

    // MARK: Typst

    mutating func lexTypst(_ start: LexState) -> LexState {
        var i = 0
        switch start.mode {
        case .blockComment:
            let (end, depth) = blockCommentEnd(typstComment, from: 0, depth: Int(start.depth))
            emit(0, end, .comment)
            if depth > 0 { return LexState(.blockComment, depth: UInt16(depth)) }
            i = end
        case .string:
            guard let end = find([Char.dollar], from: 0) else {
                emit(0, count, .string)
                return start
            }
            emit(0, end, .string)
            i = end
        case .block where start.rule == typstRaw:
            let marks = Array(repeating: Char.backtick, count: Int(start.depth))
            guard let close = find(marks, from: 0) else { return lexBlockText(0, count, start) }
            _ = lexBlockText(0, close - marks.count, start)
            emit(close - marks.count, close, .code)
            i = close
        case .block:
            let (end, depth) = lexTypstCode(from: 0, depth: Int(start.depth))
            if depth > 0 { return LexState(.block, rule: typstCodeBlock, depth: UInt16(depth)) }
            i = end
        default:
            break
        }
        let indent = firstNonSpace()
        if i == 0 && indent < count {
            let c = chars[indent]
            if c == Char.equals && Char.isSpace(at(runEnd(of: c, from: indent))) {
                emit(indent, count, .heading)
                return .normal
            }
            if (c == Char.minus || c == Char.plus) && Char.isSpace(at(indent + 1)) {
                emit(indent, indent + 1, .keyword)
                i = indent + 1
            } else if c == Char.slash && Char.isSpace(at(indent + 1)) {
                emit(indent, indent + 1, .keyword)
                i = indent + 1
                var colon = i
                while colon < count && chars[colon] != Char.colon { colon += 1 }
                if colon < count {
                    emit(firstNonSpace(from: i), colon, .property)
                    i = colon
                }
            } else if let end = orderedMarkerEnd(from: indent) {
                emit(indent, end, .keyword)
                i = end
            }
        }
        return lexTypstMarkup(from: i)
    }

    mutating func lexTypstMarkup(from start: Int) -> LexState {
        var i = start
        while i < count {
            let c = chars[i]
            if c == Char.backslash {
                i += 2
                continue
            }
            if c == Char.slash && at(i + 1) == Char.slash && (i == 0 || chars[i - 1] != Char.colon) {
                emit(i, count, .comment)
                return .normal
            }
            if c == Char.slash && at(i + 1) == Char.star {
                let (end, depth) = blockCommentEnd(typstComment, from: i + 2, depth: 1)
                emit(i, end, .comment)
                if depth > 0 { return LexState(.blockComment, depth: UInt16(depth)) }
                i = end
                continue
            }
            if c == Char.backtick {
                let marks = runEnd(of: c, from: i) - i
                if marks >= 3 { return lexTypstRaw(from: i, marks: marks) }
                if let end = find(Array(repeating: c, count: marks), from: i + marks) {
                    emit(i, end, .code)
                    i = end
                    continue
                }
                i += marks
                continue
            }
            if c == Char.dollar {
                guard let end = find([Char.dollar], from: i + 1) else {
                    emit(i, count, .string)
                    return LexState(.string)
                }
                emit(i, end, .string)
                i = end
                continue
            }
            if c == Char.star || (c == Char.underscore && (i == 0 || !Char.isIdentPart(chars[i - 1]))),
                let end = find([c], from: i + 1)
            {
                emit(i, end, c == Char.star ? .strong : .emphasis)
                i = end
                continue
            }
            if c == Char.at && Char.isIdentStart(at(i + 1)) {
                // A full stop or a colon after a reference ends its sentence.
                var end = identifierEnd(from: i + 1, extra: [Char.minus, Char.colon, Char.dot])
                while chars[end - 1] == Char.dot || chars[end - 1] == Char.colon { end -= 1 }
                emit(i, end, .link)
                i = end
                continue
            }
            if c == Char.less && Char.isIdentStart(at(i + 1)) {
                let end = identifierEnd(from: i + 1, extra: [Char.minus, Char.colon, Char.dot])
                if at(end) == Char.greater {
                    emit(i, end + 1, .attribute)
                    i = end + 1
                    continue
                }
            }
            if c == Char.hash
                && (Char.isIdentStart(at(i + 1)) || at(i + 1) == Char.openParen || at(i + 1) == Char.openBrace)
            {
                let (end, depth) = lexTypstHash(from: i)
                if depth > 0 { return LexState(.block, rule: typstCodeBlock, depth: UInt16(depth)) }
                i = end
                continue
            }
            if Char.isIdentStart(c) {
                if let end = urlEnd(from: i) {
                    emit(i, end, .link)
                    i = end
                    continue
                }
                i = identifierEnd(from: i)
                continue
            }
            i += 1
        }
        return .normal
    }

    /// ` ```rust … ``` `, its language right after its marks, and the rest of the line: the state the next line starts
    /// in, inside the block when it didn't close on this line.
    mutating func lexTypstRaw(from i: Int, marks: Int) -> LexState {
        let named = Char.isIdentStart(at(i + marks)) ? fenceLanguage(from: i + marks) : 0
        let codeStart = named == 0 ? i + marks : identifierEnd(from: i + marks, extra: [Char.minus, Char.plus])
        emit(i, codeStart, .code)
        let state = LexState(.block, rule: typstRaw, depth: UInt16(marks), embedded: named)
        let fence = Array(repeating: Char.backtick, count: marks)
        guard let close = find(fence, from: codeStart) else { return lexBlockText(codeStart, count, state) }
        _ = lexBlockText(codeStart, close - marks, state)
        emit(close - marks, close, .code)
        return lexTypstMarkup(from: close)
    }

    /// `#name`, `#name.field(args)`, `#let …`, `#{ … }`: colored, where the markup goes on, and the depth of brackets
    /// still open at the line's end.
    mutating func lexTypstHash(from i: Int) -> (end: Int, depth: Int) {
        let j = i + 1
        if at(j) == Char.openParen || at(j) == Char.openBrace {
            emit(i, j, .keyword)
            return lexTypstCode(from: j, depth: 0)
        }
        let wordEnd = identifierEnd(from: j, extra: [Char.minus])
        let name = word(j, wordEnd)
        if typstCode.keywords.contains(name) {
            emit(i, wordEnd, .keyword)
            guard typstStatements.contains(name) else { return (wordEnd, 0) }
            return lexTypstCode(from: wordEnd, depth: 0, toLineEnd: true)
        }
        if typstCode.literals.contains(name) {
            emit(i, wordEnd, .literal)
            return (wordEnd, 0)
        }
        var end = wordEnd
        while at(end) == Char.dot && Char.isIdentStart(at(end + 1)) {
            end = identifierEnd(from: end + 1, extra: [Char.minus])
        }
        emit(i, end, at(end) == Char.openParen || at(end) == Char.openBracket ? .function : .variable)
        return at(end) == Char.openParen ? lexTypstCode(from: end, depth: 0) : (end, 0)
    }

    /// Typst code from `start`, with `depth` brackets open before it: up to the bracket that closes the last of them,
    /// or to the line's end with `toLineEnd` (a `#let`). Brackets in strings and comments don't count.
    mutating func lexTypstCode(from start: Int, depth initial: Int, toLineEnd: Bool = false) -> (end: Int, depth: Int) {
        let tokens = lexCodeSegment(typstCode, start, count)
        let quiet = tokens.filter { $0.kind == .string || $0.kind == .comment }
        var depth = initial
        var end = count
        var k = start
        var next = 0
        scan: while k < count {
            while next < quiet.count && start + quiet[next].location + quiet[next].length <= k { next += 1 }
            if next < quiet.count && k >= start + quiet[next].location {
                k = start + quiet[next].location + quiet[next].length
                continue
            }
            switch chars[k] {
            case Char.openParen, Char.openBracket, Char.openBrace:
                depth += 1
            case Char.closeParen, Char.closeBracket, Char.closeBrace:
                depth -= 1
                if depth <= 0 && !toLineEnd {
                    end = k + 1
                    depth = 0
                    break scan
                }
            default:
                break
            }
            k += 1
        }
        for token in tokens where start + token.location < end {
            emit(start + token.location, min(start + token.location + token.length, end), token.kind)
        }
        return (end, max(depth, 0))
    }
}
