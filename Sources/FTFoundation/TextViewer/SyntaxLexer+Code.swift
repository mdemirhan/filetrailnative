import Foundation

extension Line {
    mutating func lexCode(_ rules: CodeRules, _ start: LexState) -> LexState {
        var i = 0
        switch start.mode {
        case .blockComment:
            let rule = rules.blockComments[Int(start.rule)]
            let (end, depth) = blockCommentEnd(rule, from: 0, depth: Int(start.depth))
            emit(0, end, .comment)
            if depth > 0 { return LexState(.blockComment, rule: start.rule, depth: UInt16(depth)) }
            i = end
        case .string:
            let rule = rules.strings[Int(start.rule)]
            let (end, closed) = stringEnd(rule, from: 0)
            emit(0, end, .string)
            if !closed { return start }
            i = end
        default:
            break
        }

        var seenNonSpace = i > 0
        var previousWord = ""
        while i < count {
            let c = chars[i]
            if Char.isSpace(c) {
                i += 1
                continue
            }
            let atLineStart = !seenNonSpace
            seenNonSpace = true

            if let (index, rule) = rules.blockComments.enumerated().first(where: { matches($0.element.open, at: i) }) {
                let (end, depth) = blockCommentEnd(rule, from: i + rule.open.count, depth: 1)
                emit(i, end, .comment)
                if depth > 0 { return LexState(.blockComment, rule: UInt16(index), depth: UInt16(depth)) }
                i = end
                continue
            }
            if rules.lineComments.contains(where: { matches($0, at: i) }),
                !rules.lineCommentsNeedSpace || i == 0 || Char.isSpace(chars[i - 1])
            {
                emit(i, count, .comment)
                return .normal
            }
            if rules.preprocessor && atLineStart && c == Char.hash {
                i = lexPreprocessor(from: i)
                continue
            }
            if let index = stringRule(rules, at: i) {
                let rule = rules.strings[index]
                let (end, closed) = stringEnd(rule, from: i + rule.open.count)
                emit(i, end, keyKind(rules, after: end) ?? .string)
                if !closed && rule.multiline { return LexState(.string, rule: UInt16(index)) }
                i = end
                continue
            }
            if Char.isDigit(c)
                || (c == Char.dot && Char.isDigit(at(i + 1)) && (i == 0 || !Char.isIdentPart(chars[i - 1])))
            {
                let end = numberEnd(from: i)
                emit(i, end, .number)
                i = end
                continue
            }
            if rules.attributePrefixes.contains(c) {
                if rules.bracketAttributes && c == Char.hash
                    && (at(i + 1) == Char.openBracket || (at(i + 1) == Char.bang && at(i + 2) == Char.openBracket))
                {
                    let end = bracketEnd(from: i)
                    emit(i, end, .attribute)
                    i = end
                    continue
                }
                if Char.isIdentStart(at(i + 1)) {
                    let end = identifierEnd(from: i + 1, extra: rules.identifierExtras)
                    emit(i, end, .attribute)
                    i = end
                    continue
                }
            }
            if let prefix = rules.variablePrefix, c == prefix, i + 1 < count {
                let end = variableEnd(from: i)
                if end > i + 1 {
                    emit(i, end, .variable)
                    i = end
                    continue
                }
            }
            if Char.isIdentStart(c) {
                let end = identifierEnd(from: i, extra: rules.identifierExtras)
                let word = word(i, end)
                if let index = stringRule(rules, at: end), rules.stringPrefixes.contains(word) {
                    let rule = rules.strings[index]
                    let (stringEnd, closed) = stringEnd(rule, from: end + rule.open.count)
                    emit(i, stringEnd, .string)
                    if !closed && rule.multiline { return LexState(.string, rule: UInt16(index)) }
                    i = stringEnd
                    continue
                }
                emit(
                    i, end, classify(word, rules, start: i, end: end, atLineStart: atLineStart, previous: previousWord))
                previousWord = word
                i = end
                continue
            }
            i += 1
        }
        return .normal
    }

    /// Which string opens at `i`, the longest opening first as the rules list them.
    func stringRule(_ rules: CodeRules, at i: Int) -> Int? {
        rules.strings.firstIndex { matches($0.open, at: i) }
    }

    /// A string followed by `:` is a key, when the rules say so.
    func keyKind(_ rules: CodeRules, after end: Int) -> SyntaxKind? {
        guard rules.keysBeforeColon else { return nil }
        return at(firstNonSpace(from: end)) == Char.colon ? .property : nil
    }

    func blockCommentEnd(_ rule: CommentRule, from i: Int, depth: Int) -> (end: Int, depth: Int) {
        var j = i
        var depth = depth
        while j < count {
            if rule.nested && matches(rule.open, at: j) {
                depth += 1
                j += rule.open.count
            } else if matches(rule.close, at: j) {
                depth -= 1
                j += rule.close.count
                if depth == 0 { return (j, 0) }
            } else {
                j += 1
            }
        }
        return (count, depth)
    }

    /// `#[…]` to its matching `]`, or the line's end.
    func bracketEnd(from i: Int) -> Int {
        var j = i
        var depth = 0
        while j < count {
            if chars[j] == Char.openBracket { depth += 1 }
            if chars[j] == Char.closeBracket {
                depth -= 1
                if depth == 0 { return j + 1 }
            }
            j += 1
        }
        return count
    }

    /// `$name`, `$1`, `$@`, `${…}`, `$(…)`.
    func variableEnd(from i: Int) -> Int {
        let next = at(i + 1)
        if next == Char.openBrace || next == Char.openParen {
            let close = next == Char.openBrace ? Char.closeBrace : Char.closeParen
            var j = i + 2
            while j < count && chars[j] != close { j += 1 }
            return min(j + 1, count)
        }
        if Char.isIdentStart(next) { return identifierEnd(from: i + 1) }
        if Char.isDigit(next)
            || [Char.at, Char.star, Char.hash, Char.question, Char.bang, Char.dollar, Char.minus]
                .contains(next)
        {
            return i + 2
        }
        return i + 1
    }

    /// `#include <stdio.h>`: the directive is an attribute, and a `<…>` after it a string.
    mutating func lexPreprocessor(from i: Int) -> Int {
        var j = firstNonSpace(from: i + 1)
        j = identifierEnd(from: j)
        emit(i, j, .attribute)
        let next = firstNonSpace(from: j)
        if at(next) == Char.less {
            var k = next + 1
            while k < count && chars[k] != Char.greater { k += 1 }
            emit(next, min(k + 1, count), .string)
            return min(k + 1, count)
        }
        return j
    }

    func classify(
        _ word: String, _ rules: CodeRules, start: Int, end: Int, atLineStart: Bool, previous: String
    ) -> SyntaxKind {
        let key = rules.lookup(word)
        let afterDot = start > 0 && chars[start - 1] == Char.dot && !(start > 1 && chars[start - 2] == Char.dot)
        if !afterDot {
            if rules.keywords.contains(key) { return .keyword }
            if rules.literals.contains(key) { return .literal }
        }
        if rules.types.contains(word) { return .type }
        let next = at(firstNonSpace(from: end))
        if rules.lineStartLabels && atLineStart && next == Char.colon && at(firstNonSpace(from: end) + 1) != Char.equals
        {
            return .function
        }
        if rules.definers.contains(rules.lookup(previous)) { return .function }
        if rules.capitalizedTypes && Char.isUpper(chars[start]) { return .type }
        if rules.functionCalls && next == Char.openParen && at(end) == Char.openParen { return .function }
        return .plain
    }
}
