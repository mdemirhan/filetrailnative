import Foundation

private let commentOpen = Array("<!--".utf16)
private let commentClose = Array("-->".utf16)
private let cdataOpen = Array("<![CDATA[".utf16)
private let cdataClose = Array("]]>".utf16)

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
            let (end, closed) = lexTagBody(from: 0)
            if !closed { return start }
            i = end
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
            let (end, closed) = lexTagBody(from: nameEnd)
            if !closed { return LexState(.markupTag) }
            i = end
        }
        return .normal
    }

    /// A tag's attributes up to its `>`, and whether the tag closed on this line.
    mutating func lexTagBody(from i: Int) -> (end: Int, closed: Bool) {
        var j = i
        while j < count {
            let c = chars[j]
            if Char.isSpace(c) || c == Char.equals {
                j += 1
            } else if c == Char.greater {
                emit(j, j + 1, .tag)
                return (j + 1, true)
            } else if (c == Char.slash || c == Char.question) && at(j + 1) == Char.greater {
                emit(j, j + 2, .tag)
                return (j + 2, true)
            } else if c == Char.quote || c == Char.apostrophe {
                var k = j + 1
                while k < count && chars[k] != c { k += 1 }
                emit(j, min(k + 1, count), .string)
                j = min(k + 1, count)
            } else if Char.isIdentStart(c) || c == Char.at || c == Char.colon {
                let end = identifierEnd(from: j + 1, extra: [Char.minus, Char.colon, Char.dot])
                emit(j, end, .property)
                j = end
            } else {
                j += 1
            }
        }
        return (count, false)
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
            emit(0, count, .code)
            var j = indent
            while j < count && chars[j] == UInt16(start.rule) { j += 1 }
            let closes = j - indent >= Int(start.depth) && firstNonSpace(from: j) == count
            return closes ? .normal : start
        }
        guard indent < count else { return .normal }
        let c = chars[indent]
        if indent < 4 && (c == Char.backtick || c == Char.tilde) {
            var j = indent
            while j < count && chars[j] == c { j += 1 }
            if j - indent >= 3 {
                emit(0, count, .code)
                return LexState(.fence, rule: c, depth: UInt16(j - indent))
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
