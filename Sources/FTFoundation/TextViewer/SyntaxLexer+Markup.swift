import Foundation

private let commentOpen = Array("<!--".utf16)
private let commentClose = Array("-->".utf16)
private let cdataOpen = Array("<![CDATA[".utf16)
private let cdataClose = Array("]]>".utf16)
private let rawTextTags = [Array("script".utf16), Array("style".utf16)]
private let scriptTag: UInt16 = 0
private let styleTag: UInt16 = 1

extension Line {
    // MARK: HTML and XML

    mutating func lexMarkup(_ start: LexState) -> LexState {
        var i = 0
        switch start.mode {
        case .markupComment:
            guard let end = find(commentClose, from: 0) else {
                emit(0, count, .comment)
                return start
            }
            emit(0, end, .comment)
            i = end
        case .markupCData:
            guard let end = find(cdataClose, from: 0) else {
                emit(0, count, .string)
                return start
            }
            emit(0, end, .string)
            i = end
        case .markupTag:
            var pending = start
            let (end, closed, selfClosed) = lexTagBody(from: 0, opening: &pending)
            if !closed { return pending }
            i = end
            if pending.embedded != 0 && !selfClosed {
                let (resume, state) = lexRawText(
                    from: i, LexState(.embedded, rule: pending.rule, embedded: pending.embedded))
                guard let resume else { return state }
                i = resume
            }
        case .embedded:
            let (resume, state) = lexRawText(from: 0, start)
            guard let resume else { return state }
            i = resume
        default:
            break
        }
        while i < count {
            let c = chars[i]
            if c == Char.amp {
                var j = i + 1
                while j < count && j - i < 12 && (Char.isIdentPart(chars[j]) || chars[j] == Char.hash) { j += 1 }
                if at(j) == Char.semicolon && j > i + 1 {
                    emit(i, j + 1, .literal)
                    i = j + 1
                    continue
                }
                i += 1
                continue
            }
            guard c == Char.less else {
                i += 1
                continue
            }
            if matches(commentOpen, at: i) {
                guard let end = find(commentClose, from: i + 4) else {
                    emit(i, count, .comment)
                    return LexState(.markupComment)
                }
                emit(i, end, .comment)
                i = end
                continue
            }
            if matches(cdataOpen, at: i) {
                guard let end = find(cdataClose, from: i + cdataOpen.count) else {
                    emit(i, count, .string)
                    return LexState(.markupCData)
                }
                emit(i, end, .string)
                i = end
                continue
            }
            var j = i + 1
            if at(j) == Char.slash || at(j) == Char.bang || at(j) == Char.question { j += 1 }
            guard Char.isIdentStart(at(j)) else {
                i += 1
                continue
            }
            let nameEnd = identifierEnd(from: j, extra: [Char.minus, Char.colon, Char.dot])
            let declaration = at(i + 1) == Char.bang || at(i + 1) == Char.question
            emit(i, nameEnd, declaration ? .meta : .tag)
            var pending = LexState(.markupTag)
            if embeds && j == i + 1, let tag = rawTextTags.firstIndex(where: { isName($0, from: j, to: nameEnd) }) {
                pending.rule = UInt16(tag)
                pending.embedded = TextLanguages.positions[tag == Int(scriptTag) ? "javascript" : "css"] ?? 0
            }
            let (end, closed, selfClosed) = lexTagBody(from: nameEnd, opening: &pending)
            if !closed { return pending }
            i = end
            if pending.embedded != 0 && !selfClosed {
                let (resume, state) = lexRawText(
                    from: i, LexState(.embedded, rule: pending.rule, embedded: pending.embedded))
                guard let resume else { return state }
                i = resume
            }
        }
        return .normal
    }

    /// Whether `chars[start..<end]` is `name`, in any case.
    func isName(_ name: [UInt16], from start: Int, to end: Int) -> Bool {
        guard end - start == name.count else { return false }
        for k in 0..<name.count where chars[start + k] | 0x20 != name[k] { return false }
        return true
    }

    /// The text of a `<script>` or a `<style>` from `i`, as its language: where its closing tag starts on this line, or
    /// nil and the state the next line starts in. The first `</script` ends a script, in a string or not, as in a
    /// browser.
    mutating func lexRawText(from i: Int, _ state: LexState) -> (resume: Int?, state: LexState) {
        let name = rawTextTags[Int(state.rule)]
        var close = i
        while close < count {
            if chars[close] == Char.less && at(close + 1) == Char.slash
                && isName(name, from: close + 2, to: min(close + 2 + name.count, count))
            {
                _ = lexEmbedded(i, close, state)
                return (close, .normal)
            }
            close += 1
        }
        return (nil, lexEmbedded(i, count, state))
    }

    /// The language of a `<script>` or a `<style>` as its `lang` or `type` says: `lang="ts"`, `lang="scss"`,
    /// `type="module"`, `type="application/ld+json"`. A script of a type no language here is (a shader, the text of a
    /// template engine) is plain text.
    func rawTextLanguage(_ tag: UInt16, attribute: String, value: String, current: UInt16) -> UInt16 {
        let value = value.lowercased().trimmingCharacters(in: .whitespaces)
        if attribute == "lang" {
            let named = TextLanguages.position(named: value)
            return named == 0 ? current : named
        }
        guard attribute == "type", tag == scriptTag else { return current }
        let id: String
        if value.contains("json") || value == "importmap" || value == "speculationrules" {
            id = "json"
        } else if value.contains("typescript") {
            id = "typescript"
        } else if value.isEmpty || value == "module"
            || ["javascript", "ecmascript", "babel", "jsx"].contains(where: value.contains)
        {
            id = "javascript"
        } else if value.contains("html") || value.contains("template") {
            id = "html"
        } else {
            id = "plain"
        }
        return TextLanguages.positions[id] ?? current
    }

    /// A tag's attributes up to its `>`, whether the tag closed on this line, and whether by `/>`. In a `<script>` or a
    /// `<style>`, `opening` takes the language its `lang` or `type` names.
    mutating func lexTagBody(from i: Int, opening: inout LexState) -> (end: Int, closed: Bool, selfClosed: Bool) {
        var j = i
        var attribute = ""
        while j < count {
            let c = chars[j]
            if Char.isSpace(c) || c == Char.equals {
                j += 1
            } else if c == Char.greater {
                emit(j, j + 1, .tag)
                return (j + 1, true, false)
            } else if (c == Char.slash || c == Char.question) && at(j + 1) == Char.greater {
                emit(j, j + 2, .tag)
                return (j + 2, true, true)
            } else if c == Char.quote || c == Char.apostrophe {
                var k = j + 1
                while k < count && chars[k] != c { k += 1 }
                emit(j, min(k + 1, count), .string)
                if opening.embedded != 0 && !attribute.isEmpty {
                    opening.embedded = rawTextLanguage(
                        opening.rule, attribute: attribute, value: word(j + 1, k), current: opening.embedded)
                }
                attribute = ""
                j = min(k + 1, count)
            } else if Char.isIdentStart(c) || c == Char.at || c == Char.colon {
                let end = identifierEnd(from: j + 1, extra: [Char.minus, Char.colon, Char.dot])
                emit(j, end, .property)
                attribute = word(j, end).lowercased()
                j = end
            } else {
                j += 1
            }
        }
        return (count, false, false)
    }

    func find(_ pattern: [UInt16], from i: Int) -> Int? {
        var j = i
        while j + pattern.count <= count {
            if matches(pattern, at: j) { return j + pattern.count }
            j += 1
        }
        return nil
    }

    // MARK: Markdown

    mutating func lexMarkdown(_ start: LexState) -> LexState {
        let indent = firstNonSpace()
        if start.mode == .fence {
            var j = indent
            while j < count && chars[j] == UInt16(start.rule) { j += 1 }
            if j - indent >= Int(start.depth) && firstNonSpace(from: j) == count {
                emit(0, count, .code)
                return .normal
            }
            guard start.embedded != 0 else {
                emit(0, count, .code)
                return start
            }
            return lexEmbedded(0, count, start)
        }
        guard indent < count else { return .normal }
        let c = chars[indent]
        if indent < 4 && (c == Char.backtick || c == Char.tilde) {
            var j = indent
            while j < count && chars[j] == c { j += 1 }
            if j - indent >= 3 {
                emit(0, count, .code)
                return LexState(.fence, rule: c, depth: UInt16(j - indent), embedded: fenceLanguage(from: j))
            }
        }
        if indent < 4 && c == Char.hash {
            var j = indent
            while j < count && chars[j] == Char.hash { j += 1 }
            if j - indent <= 6 && (j == count || Char.isSpace(chars[j])) {
                emit(0, count, .heading)
                return .normal
            }
        }
        if indent < 4 && (c == Char.minus || c == Char.star || c == Char.underscore) && isRule(from: indent, c) {
            emit(0, count, .meta)
            return .normal
        }
        var i = indent
        if c == Char.greater {
            emit(indent, count, .comment)
            return .normal
        }
        if (c == Char.minus || c == Char.star || c == Char.plus) && Char.isSpace(at(indent + 1)) {
            emit(indent, indent + 1, .keyword)
            i = indent + 2
        } else if Char.isDigit(c) {
            var j = indent
            while j < count && Char.isDigit(chars[j]) { j += 1 }
            if (at(j) == Char.dot || at(j) == Char.closeParen) && Char.isSpace(at(j + 1)) {
                emit(indent, j + 1, .keyword)
                i = j + 2
            }
        }
        lexMarkdownInline(from: i)
        return .normal
    }

    func isRule(from i: Int, _ c: UInt16) -> Bool {
        var marks = 0
        for j in i..<count {
            if chars[j] == c {
                marks += 1
            } else if !Char.isSpace(chars[j]) {
                return false
            }
        }
        return marks >= 3
    }

    mutating func lexMarkdownInline(from start: Int) {
        var i = start
        while i < count {
            let c = chars[i]
            if c == Char.backslash {
                i += 2
                continue
            }
            if c == Char.backtick {
                var ticks = i
                while ticks < count && chars[ticks] == Char.backtick { ticks += 1 }
                let run = Array(repeating: Char.backtick, count: ticks - i)
                if let end = find(run, from: ticks) {
                    emit(i, end, .code)
                    i = end
                    continue
                }
                i = ticks
                continue
            }
            if c == Char.star || c == Char.underscore {
                let double = at(i + 1) == c
                let width = double ? 2 : 1
                let wordStart = c == Char.star || i == 0 || !Char.isIdentPart(chars[i - 1])
                if wordStart && !Char.isSpace(at(i + width)) && i + width < count,
                    let end = find(Array(repeating: c, count: width), from: i + width + 1)
                {
                    emit(i, end, double ? .strong : .emphasis)
                    i = end
                    continue
                }
                i += width
                continue
            }
            if c == Char.openBracket || (c == Char.bang && at(i + 1) == Char.openBracket) {
                let open = c == Char.bang ? i + 1 : i
                var j = open + 1
                while j < count && chars[j] != Char.closeBracket { j += 1 }
                if j < count && at(j + 1) == Char.openParen {
                    var k = j + 2
                    while k < count && chars[k] != Char.closeParen { k += 1 }
                    emit(i, j + 1, .link)
                    emit(j + 1, min(k + 1, count), .meta)
                    i = min(k + 1, count)
                    continue
                }
                i = open + 1
                continue
            }
            if c == Char.less && Char.isLetter(at(i + 1)) {
                var j = i + 1
                while j < count && chars[j] != Char.greater && !Char.isSpace(chars[j]) { j += 1 }
                if at(j) == Char.greater && word(i + 1, j).contains(":") {
                    emit(i, j + 1, .link)
                    i = j + 1
                    continue
                }
            }
            i += 1
        }
    }

    // MARK: Diff

    mutating func lexDiff() -> LexState {
        guard count > 0 else { return .normal }
        let c = chars[0]
        if matches(Array("+++".utf16), at: 0) || matches(Array("---".utf16), at: 0) {
            emit(0, count, .meta)
        } else if c == Char.plus {
            emit(0, count, .inserted)
        } else if c == Char.minus {
            emit(0, count, .deleted)
        } else if matches(Array("@@".utf16), at: 0) {
            emit(0, count, .meta)
        } else if matches(Array("diff ".utf16), at: 0) || matches(Array("index ".utf16), at: 0) {
            emit(0, count, .keyword)
        }
        return .normal
    }
}
