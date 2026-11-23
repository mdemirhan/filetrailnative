import AppKit
import QuartzCore

/// Moves a scroll view smoothly while an arrow key is held, as a web view does: a press glides a short way, a key held
/// down goes faster the longer it is held, and letting go eases it to a stop. Moved by each key event alone, the view
/// would jump once per key repeat, slowly and in steps.
@MainActor
final class ViewerKeyScroller: NSObject {
    // About two thirds of a web view's arrows' speed, timed on one, which felt faster than a Word document's preview
    // (the owner, twice a fifth slower): a press moves about 30 points, and a key held reaches about 665 points a
    // second within a sixth of a second, stopping within about 25 points when let go.
    /// Where a press glides at the least, in points.
    static let pressDistance: CGFloat = 30
    /// The speed a press starts at, and the most a key held down reaches, in points a second.
    static let startSpeed: CGFloat = 96
    static let topSpeed: CGFloat = 665
    /// How fast a key held down speeds up, and how fast it slows once let go, in points a second each second.
    static let acceleration: CGFloat = 3840
    static let braking: CGFloat = 8640

    private weak var scrollView: NSScrollView?
    private var link: CADisplayLink?
    /// The way it moves: x right, y down the document, each -1, 0 or 1.
    private var direction = CGVector.zero
    private var keyCode: UInt16?
    private var speed: CGFloat = 0
    private var travelled: CGFloat = 0
    /// What is left to go once the key is let go; nil while it is held.
    private var remaining: CGFloat?
    private var lastFrame: CFTimeInterval?
    private var lastKey = Date.distantPast

    /// Moves `scrollView`, or the one its view gives as it changes (a PDF's own scroll view).
    private let scrollViewOf: () -> NSScrollView?

    init(_ scrollViewOf: @escaping () -> NSScrollView?) {
        self.scrollViewOf = scrollViewOf
    }

    var isMoving: Bool { link != nil }

    /// Takes a plain arrow key: true when it moves, or was a repeat of the key held.
    func keyDown(_ event: NSEvent, horizontal: Bool = true) -> Bool {
        guard event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return false }
        let way: CGVector
        switch event.charactersIgnoringModifiers?.unicodeScalars.first.map({ Int($0.value) }) {
        case NSUpArrowFunctionKey: way = CGVector(dx: 0, dy: -1)
        case NSDownArrowFunctionKey: way = CGVector(dx: 0, dy: 1)
        case NSLeftArrowFunctionKey where horizontal: way = CGVector(dx: -1, dy: 0)
        case NSRightArrowFunctionKey where horizontal: way = CGVector(dx: 1, dy: 0)
        default: return false
        }
        lastKey = Date()
        if event.isARepeat, keyCode == event.keyCode, remaining == nil { return true }
        guard let scrollView = scrollViewOf() else { return false }
        if way != direction || !isMoving { speed = Self.startSpeed }
        direction = way
        keyCode = event.keyCode
        travelled = 0
        remaining = nil
        self.scrollView = scrollView
        start(on: scrollView)
        return true
    }

    /// The key held is let go: it eases to a stop, past where a press goes.
    func keyUp(_ event: NSEvent) {
        guard event.keyCode == keyCode, remaining == nil else { return }
        letGo()
    }

    func stop() {
        link?.invalidate()
        link = nil
        lastFrame = nil
        keyCode = nil
        remaining = nil
        direction = .zero
    }

    private func letGo() {
        // Stopping at a steady rate from the speed it has, and at least as far as a press.
        let stopping = speed * speed / (2 * Self.braking)
        remaining = max(Self.pressDistance - travelled, stopping)
    }

    private func start(on view: NSView) {
        guard link == nil else { return }
        let link = view.displayLink(target: self, selector: #selector(frame(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func frame(_ link: CADisplayLink) {
        let now = link.timestamp
        let elapsed = min(max(now - (lastFrame ?? now - link.duration), 0), 1.0 / 20)
        lastFrame = now
        let dt = CGFloat(elapsed)
        if remaining == nil {
            // A key held sends its repeats; with none for longer than they come, its key-up went elsewhere.
            let wait = max(NSEvent.keyRepeatDelay, NSEvent.keyRepeatInterval) + 0.25
            if Date().timeIntervalSince(lastKey) > wait {
                letGo()
            } else {
                speed = min(Self.topSpeed, speed + Self.acceleration * dt)
            }
        }
        var step = speed * dt
        if let left = remaining {
            // Slows evenly to nothing over what is left.
            let slowing = speed * speed / (2 * max(left, 0.5))
            speed = max(0, speed - slowing * dt)
            step = min(max(step, 0.5), left)
            remaining = left - step
        }
        travelled += step
        guard move(by: step), (remaining ?? 1) > 0.25 else {
            stop()
            return
        }
    }

    /// False at the end, where it can't move.
    private func move(by step: CGFloat) -> Bool {
        guard let scrollView, scrollView.window != nil, let document = scrollView.documentView else { return false }
        let clip = scrollView.contentView
        var bounds = clip.bounds
        bounds.origin.x += direction.dx * step
        bounds.origin.y += (document.isFlipped ? 1 : -1) * direction.dy * step
        let next = clip.constrainBoundsRect(bounds).origin
        guard abs(next.x - clip.bounds.origin.x) > 0.01 || abs(next.y - clip.bounds.origin.y) > 0.01 else {
            return false
        }
        clip.scroll(to: next)
        scrollView.reflectScrolledClipView(clip)
        return true
    }
}
