import Foundation

private let yamlLiterals: Set<String> = [
    "true", "false", "yes", "no", "on", "off", "null", "True", "False", "Yes", "No", "On", "Off", "Null", "TRUE",
    "FALSE", "NULL", "~",
]
private let tomlLiterals: Set<String> = ["true", "false", "inf", "nan"]
private let tripleQuote = Array("\"\"\"".utf16)
private let tripleApostrophe = Array("'''".utf16)
private let cssImportant = Array("!important".utf16)

extension Line {
    // MARK: YAML

    mutating func lexYAML(_ start: LexState) -> LexState {
        let indent = firstNonSpace()
        if start.mode == .blockScalar {
            if indent == count || indent > Int(start.depth) {
                emit(indent, count, .string)
                return start
            }
        }
        guard indent < count else { return .normal }
        if indent == 0 && (matches(Array("---".utf16), at: 0) || matches(Array("...".utf16), at: 0)) {
            emit(0, 3, .meta)
            return .normal
        }
        var i = indent
        while at(i) == Char.minus && (Char.isSpace(at(i + 1)) || i + 1 == count) {
            i = firstNonSpace(from: i + 1)
        }
        if at(i) == Char.hash {
            emit(i, count, .comment)
            return .normal
        }
        if let colon = yamlKeyEnd(from: i) {
            emit(i, colon, .property)
            i = colon + 1
        }
        return lexYAMLValue(from: i, indent: indent)
    }

    /// The `:` that ends a key starting at `i`, if the line has one before its value.
    func yamlKeyEnd(from i: Int) -> Int? {
        var j = i
        var quote: UInt16 = 0
        while j < count {
            let c = chars[j]
            if quote != 0 {
                if c == quote { quote = 0 }
            } else if (c == Char.quote || c == Char.apostrophe) && j == i {
                quote = c
            } else if c == Char.colon && (j + 1 == count || Char.isSpace(chars[j + 1])) {
                return j > i ? j : nil
            } else if c == Char.hash && j > i && Char.isSpace(chars[j - 1]) {
                return nil
            } else if c == Char.openBrace || c == Char.openBracket {
                return nil
            }
            j += 1
        }
        return nil
    }

    mutating func lexYAMLValue(from start: Int, indent: Int) -> LexState {
        var i = firstNonSpace(from: start)
        let valueStart = i
        while i < count {
            let c = chars[i]
            if Char.isSpace(c) || c == Char.comma || c == Char.openBracket || c == Char.closeBracket
                || c == Char.openBrace || c == Char.closeBrace
            {
                i += 1
                continue
            }
            if c == Char.hash && (i == 0 || Char.isSpace(chars[i - 1])) {
                emit(i, count, .comment)
                break
            }
            if (c == Char.pipe || c == Char.greater) && i == valueStart {
                var j = i + 1
                while j < count && (chars[j] == Char.minus || chars[j] == Char.plus || Char.isDigit(chars[j])) {
                    j += 1
                }
                if firstNonSpace(from: j) == count || at(firstNonSpace(from: j)) == Char.hash {
                    emit(i, j, .keyword)
                    return LexState(.blockScalar, depth: UInt16(indent))
                }
            }
            if c == Char.quote || c == Char.apostrophe {
                var j = i + 1
                while j < count && chars[j] != c {
                    if c == Char.quote && chars[j] == Char.backslash { j += 1 }
                    j += 1
                }
                emit(i, min(j + 1, count), .string)
                i = min(j + 1, count)
                continue
            }
            if c == Char.amp || c == Char.star {
                let end = identifierEnd(from: i + 1, extra: [Char.minus])
                emit(i, end, .variable)
                i = max(end, i + 1)
                continue
            }
            if c == Char.bang {
                var j = i + 1
                while j < count && !Char.isSpace(chars[j]) { j += 1 }
                emit(i, j, .attribute)
                i = j
                continue
            }
            // A plain scalar runs to a comment or the line's end; inside [ ] or { } to a comma or a bracket.
            var j = i
            while j < count {
                let d = chars[j]
                if d == Char.hash && Char.isSpace(chars[j - 1]) { break }
                if [Char.comma, Char.closeBracket, Char.closeBrace].contains(d) { break }
                j += 1
            }
            var end = j
            while end > i && Char.isSpace(chars[end - 1]) { end -= 1 }
            let text = word(i, end)
            if yamlLiterals.contains(text) {
                emit(i, end, .literal)
            } else if Double(text) != nil
                || (Char.isDigit(chars[i]) && text.allSatisfy { $0.isNumber || "._-:".contains($0) })
            {
                emit(i, end, .number)
            }
            i = j
        }
        return .normal
    }

    // MARK: INI, TOML, .env, properties

    mutating func lexINI(_ rules: INIRules, _ start: LexState) -> LexState {
        if start.mode == .string {
            let close = start.rule == 0 ? tripleQuote : tripleApostrophe
            guard let end = find(close, from: 0) else {
                emit(0, count, .string)
                return start
            }
            emit(0, end, .string)
            return lexTOMLValue(from: end)
        }
        let i = firstNonSpace()
        guard i < count else { return .normal }
        let c = chars[i]
        if c == Char.hash || (rules.semicolonComments && c == Char.semicolon)
            || (rules.colonSeparates && c == Char.bang)
        {
            emit(i, count, .comment)
            return .normal
        }
        if c == Char.openBracket {
            var j = i
            while j < count && chars[j] != Char.closeBracket { j += 1 }
            while at(j + 1) == Char.closeBracket { j += 1 }
            emit(i, min(j + 1, count), .heading)
            return .normal
        }
        var keyStart = i
        if rules.exportKeyword && matches(Array("export ".utf16), at: i) {
            emit(i, i + 6, .keyword)
            keyStart = firstNonSpace(from: i + 7)
        }
        var j = keyStart
        while j < count && chars[j] != Char.equals && !(rules.colonSeparates && chars[j] == Char.colon) { j += 1 }
        guard j < count else { return .normal }
        var keyEnd = j
        while keyEnd > keyStart && Char.isSpace(chars[keyEnd - 1]) { keyEnd -= 1 }
        emit(keyStart, keyEnd, .property)
        if rules.typedValues { return lexTOMLValue(from: j + 1) }
        let valueStart = firstNonSpace(from: j + 1)
        if at(valueStart) == Char.quote || at(valueStart) == Char.apostrophe {
            emit(valueStart, count, .string)
        }
        return .normal
    }

    mutating func lexTOMLValue(from start: Int) -> LexState {
        var i = start
        while i < count {
            let c = chars[i]
            if c == Char.hash {
                emit(i, count, .comment)
                return .normal
            }
            if matches(tripleQuote, at: i) || matches(tripleApostrophe, at: i) {
                let close = c == Char.quote ? tripleQuote : tripleApostrophe
                guard let end = find(close, from: i + 3) else {
                    emit(i, count, .string)
                    return LexState(.string, rule: c == Char.quote ? 0 : 1)
                }
                emit(i, end, .string)
                i = end
                continue
            }
            if c == Char.quote || c == Char.apostrophe {
                var j = i + 1
                while j < count && chars[j] != c {
                    if c == Char.quote && chars[j] == Char.backslash { j += 1 }
                    j += 1
                }
                emit(i, min(j + 1, count), .string)
                i = min(j + 1, count)
                continue
            }
            if Char.isDigit(c) || ((c == Char.plus || c == Char.minus) && Char.isDigit(at(i + 1))) {
                var j = i + 1
                while j < count
                    && (Char.isIdentPart(chars[j]) || [Char.dot, Char.colon, Char.minus, Char.plus].contains(chars[j]))
                {
                    j += 1
                }
                emit(i, j, .number)
                i = j
                continue
            }
            if Char.isIdentStart(c) {
                let end = identifierEnd(from: i, extra: [Char.minus])
                if tomlLiterals.contains(word(i, end)) { emit(i, end, .literal) }
                if at(firstNonSpace(from: end)) == Char.equals { emit(i, end, .property) }
                i = end
                continue
            }
            i += 1
        }
        return .normal
    }

    // MARK: CSS

    mutating func lexCSS(_ rules: CSSRules, _ start: LexState) -> LexState {
        var i = 0
        var depth = Int(start.depth)
        if start.mode == .blockComment {
            guard let end = find(Array("*/".utf16), from: 0) else {
                emit(0, count, .comment)
                return start
            }
            emit(0, end, .comment)
            i = end
        }
        var inValue = false
        while i < count {
            let c = chars[i]
            if c == Char.slash && at(i + 1) == Char.star {
                guard let end = find(Array("*/".utf16), from: i + 2) else {
                    emit(i, count, .comment)
                    return LexState(.blockComment, depth: UInt16(max(depth, 0)))
                }
                emit(i, end, .comment)
                i = end
                continue
            }
            if rules.lineComments && c == Char.slash && at(i + 1) == Char.slash {
                emit(i, count, .comment)
                break
            }
            switch c {
            case Char.openBrace:
                depth += 1
                inValue = false
                i += 1
                continue
            case Char.closeBrace:
                depth = max(depth - 1, 0)
                inValue = false
                i += 1
                continue
            case Char.semicolon:
                inValue = false
                i += 1
                continue
            case Char.quote, Char.apostrophe:
                var j = i + 1
                while j < count && chars[j] != c {
                    if chars[j] == Char.backslash { j += 1 }
                    j += 1
                }
                emit(i, min(j + 1, count), .string)
                i = min(j + 1, count)
                continue
            default:
                break
            }
            if c == Char.at
                && !(rules.variablePrefix == Char.at && depth > 0 && !inValue
                    && at(firstNonSpace(from: identifierEnd(from: i + 1, extra: [Char.minus]))) == Char.colon)
            {
                let end = identifierEnd(from: i + 1, extra: [Char.minus])
                emit(i, end, rules.variablePrefix == Char.at && inValue ? .variable : .keyword)
                i = max(end, i + 1)
                continue
            }
            if let prefix = rules.variablePrefix, c == prefix, Char.isIdentStart(at(i + 1)) {
                let end = identifierEnd(from: i + 1, extra: [Char.minus])
                emit(i, end, .variable)
                i = end
                continue
            }
            if c == Char.minus && at(i + 1) == Char.minus && Char.isIdentStart(at(i + 2)) {
                let end = identifierEnd(from: i + 2, extra: [Char.minus])
                let isProperty = !inValue && at(firstNonSpace(from: end)) == Char.colon
                emit(i, end, isProperty ? .property : .variable)
                i = end
                continue
            }
            if matches(cssImportant, at: i) {
                emit(i, i + cssImportant.count, .keyword)
                i += cssImportant.count
                continue
            }
            if c == Char.hash && inValue {
                let end = identifierEnd(from: i + 1)
                emit(i, end, .number)
                i = max(end, i + 1)
                continue
            }
            if (c == Char.hash || c == Char.dot) && !inValue && Char.isIdentStart(at(i + 1)) {
                let end = identifierEnd(from: i + 1, extra: [Char.minus])
                emit(i, end, .attribute)
                i = end
                continue
            }
            if Char.isDigit(c) || (c == Char.dot && Char.isDigit(at(i + 1))) {
                var j = numberEnd(from: i)
                if at(j) == Char.percent { j += 1 }
                emit(i, j, .number)
                i = j
                continue
            }
            if Char.isIdentStart(c) {
                let end = identifierEnd(from: i, extra: [Char.minus])
                let next = at(firstNonSpace(from: end))
                if inValue {
                    emit(i, end, next == Char.openParen ? .function : .plain)
                } else if depth > 0 && next == Char.colon && !isSelectorAfterColon(end) {
                    emit(i, end, .property)
                    inValue = true
                    i = firstNonSpace(from: end) + 1
                    continue
                } else {
                    emit(i, end, .tag)
                }
                i = end
                continue
            }
            i += 1
        }
        return depth > 0 ? LexState(.normal, depth: UInt16(depth)) : .normal
    }

    /// `a:hover {` is a selector, `color: red` a property: a selector's line has a `{` and no `;` after the colon.
    func isSelectorAfterColon(_ i: Int) -> Bool {
        var j = i
        while j < count {
            if chars[j] == Char.semicolon { return false }
            if chars[j] == Char.openBrace { return true }
            j += 1
        }
        return false
    }
}
