// Port of the request rules of apps/desktop/src/renderer/hooks/usePathSuggestions.ts (and requestPathSuggestions of
// apps/desktop/src/renderer/App.tsx)
import Foundation

/// When a box asks the disk for completions, and which answers it drops: a request 350 ms after the last change
/// (earlier ones cancelled), and an answer only while the box is open, for the newest request, and while the field
/// still holds the text asked about. A request that failed counts as no completions.
@MainActor
public final class PathCompletionRequests {
    /// `PATH_SUGGESTION_DEBOUNCE_MS`.
    public static let debounce = 0.35
    /// `requestPathSuggestions`'s `limit`.
    public static let limit = 12

    public var timers: any TimerScheduling
    /// Asks the disk; nil when the request failed.
    public var request: @MainActor (String) async -> [GoToCompletion]?
    /// An answer that was kept.
    public var onAnswer: @MainActor ([GoToCompletion]) -> Void = { _ in }
    public private(set) var isOpen = false
    private var timer: TimerToken?
    private var requestID = 0
    private var pendingInput = ""

    public init(
        timers: any TimerScheduling, request: @escaping @MainActor (String) async -> [GoToCompletion]?
    ) {
        self.timers = timers
        self.request = request
    }

    /// The box opened (or closed): what waits is dropped, and an open box starts with a request for the empty field.
    public func setOpen(_ open: Bool) {
        timer?.cancel()
        timer = nil
        isOpen = open
        pendingInput = ""
        if open { schedule("") }
    }

    /// The field holds `value`; with `requests`, its completions are asked for after the pause.
    public func setValue(_ value: String, requests: Bool) {
        pendingInput = value
        if requests { schedule(value) }
    }

    /// Whether a request waits for the pause to end.
    public var isScheduled: Bool { timer != nil }

    private func schedule(_ input: String) {
        timer?.cancel()
        timer = timers.schedule(after: Self.debounce) { [weak self] in
            guard let self else { return }
            self.timer = nil
            self.send(input)
        }
    }

    /// The request goes now; its answer is looked at when it comes.
    private func send(_ input: String) {
        pendingInput = input
        requestID += 1
        let id = requestID
        let request = request
        Task { @MainActor [weak self] in
            let answer = await request(input)
            guard let self, self.isOpen, self.requestID == id, self.pendingInput == input else { return }
            self.onAnswer(answer ?? [])
        }
    }

    /// `requestPathSuggestions`: what is sent for a typed text, trimmed with `~` expanded.
    public static func requestPath(_ input: String, homePath: String) -> String {
        PathText2.expandHome(JSString.trimmed(input), homePath: homePath)
    }
}
