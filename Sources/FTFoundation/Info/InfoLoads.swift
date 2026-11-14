import Foundation

/// The properties the Info panel and the Info Row show for their item, read from disk a moment after the item changes.
/// What is shown stays until the next answer for the item comes; the last few answers are kept, so an item seen again
/// shows at once while it is read again. An item asked for again while a read of it is still on its way (its folder
/// changed) may be answered out of order: an answer to an older request than the one kept is dropped.
public struct InfoPropertiesLoad: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// Nothing asked: the panel and the row are closed, or there is no folder.
        case idle
        /// `path` is asked for. `fromRecent`: what was kept of it shows meanwhile, so nothing says it is loading.
        case asking(path: String, fromRecent: Bool)
        /// The answer for `path` is shown.
        case answered(path: String)
    }

    private struct Kept: Equatable, Sendable {
        var path: String
        var item: InfoItem
        /// The request it answered.
        var request: Int
    }

    public private(set) var phase = Phase.idle
    /// What is shown, which may still be another item's until the answer comes.
    public private(set) var shown: InfoItem?
    private var recent: [Kept] = []
    /// Goes up with each request.
    public private(set) var requests = 0
    public let recentLimit: Int

    public init(recentLimit: Int) {
        self.recentLimit = recentLimit
    }

    /// The item asked for or answered; nil while idle.
    public var target: String? {
        switch phase {
        case .idle: nil
        case .asking(let path, _), .answered(let path): path
        }
    }

    /// Whether the views wait for an answer with nothing of the item to show.
    public var isLoading: Bool {
        if case .asking(_, fromRecent: false) = phase { return true }
        return false
    }

    /// Whether `path` should be asked for: it isn't the item asked for already, or nothing is shown and nothing is on
    /// its way.
    public func needsAsking(_ path: String) -> Bool {
        target != path || (shown == nil && !isLoading)
    }

    /// `path` is asked for: what was kept of it shows at once. The request, to answer with.
    @discardableResult
    public mutating func ask(_ path: String) -> Int {
        requests += 1
        if let kept = recent.first(where: { $0.path == path }) {
            shown = kept.item
            phase = .asking(path: path, fromRecent: true)
        } else {
            phase = .asking(path: path, fromRecent: false)
        }
        return requests
    }

    /// Nothing is asked any more (the panel and the row closed, no folder): nothing loads.
    public mutating func stop() {
        phase = .idle
    }

    /// The answer to `request` for `path` came. It is kept unless a later request's answer for the item is; whether it
    /// is shown, since a later item may have been asked for meanwhile.
    public mutating func answered(_ path: String, _ item: InfoItem, request: Int) -> Bool {
        if let kept = recent.first(where: { $0.path == path }), kept.request > request { return false }
        recent.removeAll { $0.path == path }
        recent.append(Kept(path: path, item: item, request: request))
        if recent.count > recentLimit { recent.removeFirst(recent.count - recentLimit) }
        guard target == path else { return false }
        shown = item
        phase = .answered(path: path)
        return true
    }
}

/// The apps the Info panel offers to open its item with, which macOS is asked for a moment after the item changes.
/// While the answer is slow the panel doesn't wait for it for long: it gives up showing "Opens with" as pending.
public struct OpenWithLookupLoad<Answer: Equatable & Sendable>: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case waiting
        /// Too slow: the panel goes on without it, and takes it if it still comes.
        case gaveUp
        case answered(Answer?)
    }

    /// The item asked about; nil before anything was asked, or after the answers were forgotten.
    public private(set) var path: String?
    public private(set) var phase = Phase.waiting
    /// Goes up with each request, so an answer to one asked before (the same item asked again) is dropped.
    public private(set) var generation = 0

    public init() {}

    /// Asks about `path`. The request's generation, or nil when it is the item asked about already.
    public mutating func request(_ path: String) -> Int? {
        guard self.path != path else { return nil }
        self.path = path
        phase = .waiting
        generation += 1
        return generation
    }

    /// The wait for the request `generation` ran out. Whether that changed anything.
    public mutating func patienceRanOut(_ generation: Int) -> Bool {
        guard generation == self.generation, phase == .waiting else { return false }
        phase = .gaveUp
        return true
    }

    /// macOS answered the request `generation`. Whether it is taken.
    public mutating func answered(_ generation: Int, _ answer: Answer?) -> Bool {
        guard generation == self.generation, path != nil else { return false }
        phase = .answered(answer)
        return true
    }

    /// Every answer is forgotten (Always Open With changed what a kind opens in). The item to ask about again.
    public mutating func forget() -> String? {
        let asked = path
        path = nil
        phase = .waiting
        return asked
    }

    /// The answer for `path`, if it is the item asked about and macOS answered.
    public func answer(for path: String) -> Answer? {
        guard self.path == path, case .answered(let answer) = phase else { return nil }
        return answer
    }

    /// What "Opens with" shows for `path`: pending until there is an answer or the wait ran out, then available if the
    /// answer lets its kind always open in an app. Only files have it.
    public func opensWith(for path: String, isFile: Bool, canAlways: (Answer?) -> Bool)
        -> InfoPanelModel.OpensWithState
    {
        guard isFile else { return .hidden }
        let ready = self.path == path && phase != .waiting
        guard ready else { return .pending }
        return canAlways(answer(for: path)) ? .available : .hidden
    }
}
