import Foundation

/// One match of a pattern in a name: `groups[0]` is the whole match, `nil` a group that took no part.
struct RenameMatch: Equatable {
    /// UTF-16 offset of the match in the searched text.
    let index: Int
    let groups: [String?]
    /// What each named group matched; nil when the pattern names no group.
    let namedGroups: [String: String?]?

    var text: String { groups[0] ?? "" }
}

/// What Replace Text looks for in a name: a regular expression as `NSRegularExpression` (ICU) reads it, or text as
/// typed. The rules are ICU's own: `\d`, `\w`, `\s` and `\b` are Unicode's, `$` is the end of the name, a group is
/// named `(?<name>…)` with letters and digits and referred to as `\k<name>`, and ignoring case folds as ICU does
/// ("ss" finds "ß").
public struct RenamePattern: @unchecked Sendable {
    /// A pattern `NSRegularExpression` can't read. It says no more than that itself, so there is nothing to pass on.
    public struct Invalid: Error {}

    /// How long a pattern may work over one name, in the CPU time of the thread matching it (`ThreadTimeBudget`). A
    /// name is 255 units at most, which any ordinary pattern is through in microseconds; one that backtracks without
    /// end (`(a+)+$`) would otherwise keep the Rename sheet from answering for minutes.
    public static let timePerName: DispatchTimeInterval = .milliseconds(50)

    /// How long a pattern may work over all the names it is given, in the same CPU time: this, and
    /// `timePerCharacter` more for each UTF-16 unit of the names so far. The Rename sheet makes the pattern anew at
    /// each change of its settings and matches every name with it before it answers, so names that each stay under
    /// `timePerName` would all be matched: 200 names of nineteen "a"s under `(a+)+$`, 36 ms each, kept the sheet
    /// for 7 s at every key typed.
    public static let timeForAllNames: DispatchTimeInterval = .milliseconds(250)

    /// What each UTF-16 unit of a name adds to `timeForAllNames`. The time an ordinary pattern takes grows with the
    /// length of the names, so the limit does: over 50,000 names of 9 to 245 units, patterns that go through a name
    /// once took up to 0.5 µs a unit, and ones that go through it again from each place in it (`.*foo` where there
    /// is no "foo", `(.+)\1`) up to 1.8 µs a unit, on an M4 Max. Over five times that leaves slower Macs room.
    public static let timePerCharacter: DispatchTimeInterval = .microseconds(10)

    /// The time the pattern has used. It is over once a name took it too long, or all the names so far did: no more
    /// names are matched, as the next would likely take as long.
    private final class TimeUsed: @unchecked Sendable {
        private static let forOneName = ThreadTimeBudget.nanoseconds(RenamePattern.timePerName)
        private static let forAllNames = ThreadTimeBudget.nanoseconds(RenamePattern.timeForAllNames)
        private static let forEachCharacter = ThreadTimeBudget.nanoseconds(RenamePattern.timePerCharacter)

        private let lock = NSLock()
        private var over = false
        /// What the names so far may take together, and what they took, in nanoseconds.
        private var allowed = TimeUsed.forAllNames
        private var spent: UInt64 = 0

        var isOver: Bool { lock.withLock { over } }
        func setOver() { lock.withLock { over = true } }

        /// The nanoseconds a name of `length` UTF-16 units may take: `timePerName`, or what the names before it left
        /// of the time for all of them, when that is less.
        func timeForName(length: Int) -> UInt64 {
            lock.withLock {
                allowed += UInt64(length) * Self.forEachCharacter
                return min(Self.forOneName, allowed - min(spent, allowed))
            }
        }

        /// A name took `nanoseconds`.
        func add(_ nanoseconds: UInt64) {
            lock.withLock {
                spent += nanoseconds
                if spent > allowed { over = true }
            }
        }
    }

    private let timeUsed = TimeUsed()
    /// Whether the pattern took longer than `timePerName` over a name, or than `timeForAllNames` allows over all of
    /// them: what it matched since is not to be relied on.
    public var tookTooLong: Bool { timeUsed.isOver }

    private let regex: NSRegularExpression
    /// The names the pattern gives its groups, for `$<name>` in a replacement.
    private let groupNames: [String]

    /// The regular expression as typed, matched everywhere in a name, ignoring case when asked.
    public init(regex source: String, ignoreCase: Bool) throws {
        do {
            regex = try NSRegularExpression(pattern: source, options: ignoreCase ? [.caseInsensitive] : [])
        } catch {
            throw Invalid()
        }
        groupNames = Self.groupNames(in: source)
    }

    /// A pattern that matches `text` itself, as typed: none of its characters has a meaning of its own.
    public init(literal text: String, ignoreCase: Bool) throws {
        let pattern = text.unicodeScalars.map { Self.literal($0, ignoreCase: ignoreCase) }.joined()
        do {
            regex = try NSRegularExpression(pattern: pattern, options: ignoreCase ? [.caseInsensitive] : [])
        } catch {
            throw Invalid()
        }
        groupNames = []
    }

    /// `NSRegularExpression` doesn't list a pattern's group names, so they are read from it: every `(?<name>`. One
    /// that isn't a group (inside `[…]`, after a backslash) is a name no match has, which costs nothing.
    private static func groupNames(in source: String) -> [String] {
        guard let opening = try? NSRegularExpression(pattern: "\\(\\?<([A-Za-z][A-Za-z0-9]*)>") else { return [] }
        let string = source as NSString
        return opening.matches(in: source, range: NSRange(location: 0, length: string.length)).map {
            string.substring(with: $0.range(at: 1))
        }
    }

    /// Characters whose full case folding is several characters and has no simple folding (ligatures such as "ﬁ",
    /// "ŉ", "İ"): even in a set, ICU lets them match the folded text ("fi").
    private static let foldsToSeveral: Set<UInt32> = [
        0x130, 0x149, 0x1F0, 0x587, 0x1E96, 0x1E97, 0x1E98, 0x1E99, 0x1E9A, 0x1F50, 0x1F52, 0x1F54, 0x1F56, 0x1FB2,
        0x1FB4, 0x1FB6, 0x1FB7, 0x1FC2, 0x1FC4, 0x1FC6, 0x1FC7, 0x1FD2, 0x1FD6, 0x1FD7, 0x1FE2, 0x1FE4, 0x1FE6,
        0x1FE7, 0x1FF2, 0x1FF4, 0x1FF6, 0x1FF7, 0xFB00, 0xFB01, 0xFB02, 0xFB03, 0xFB04, 0xFB13, 0xFB14, 0xFB15,
        0xFB16, 0xFB17,
    ]

    /// One character of plain text. Ignoring case, it finds its other case and nothing longer: ICU folds a run of
    /// letters as a string, so "ss" typed as text would find "ß"; a set of one character folds that character alone.
    private static func literal(_ scalar: Unicode.Scalar, ignoreCase: Bool) -> String {
        let hex = "\\x{\(String(scalar.value, radix: 16, uppercase: true))}"
        guard ignoreCase else { return hex }
        // Those characters have no other case form, so they are matched as they are.
        return foldsToSeveral.contains(scalar.value) ? "(?-i:\(hex))" : "[\(hex)]"
    }

    /// Every match in `text`, from the left, none overlapping; none once the pattern took too long (`tookTooLong`).
    func matches(in text: String) -> [RenameMatch] {
        guard !timeUsed.isOver else { return [] }
        let string = text as NSString
        var found: [NSTextCheckingResult] = []
        let started = ThreadTimeBudget.now()
        let budget = ThreadTimeBudget(nanoseconds: timeUsed.timeForName(length: string.length), from: started)
        // The block is called with each match, and now and then while a long one is looked for.
        regex.enumerateMatches(
            in: text, options: [.reportProgress], range: NSRange(location: 0, length: string.length)
        ) { result, _, stop in
            if let result {
                found.append(result)
            } else if budget.isSpent {
                timeUsed.setOver()
                stop.pointee = true
            }
        }
        // Names too quick for the block to be called between matches still add up.
        timeUsed.add(ThreadTimeBudget.now() - started)
        guard !timeUsed.isOver else { return [] }
        func substring(_ range: NSRange) -> String? {
            range.location == NSNotFound ? nil : string.substring(with: range)
        }
        return found.map { result in
            var named: [String: String?]?
            if !groupNames.isEmpty {
                named = [:]
                for name in groupNames { named?[name] = .some(substring(result.range(withName: name))) }
            }
            let groups = (0..<result.numberOfRanges).map { substring(result.range(at: $0)) }
            return RenameMatch(index: result.range.location, groups: groups, namedGroups: named)
        }
    }
}
