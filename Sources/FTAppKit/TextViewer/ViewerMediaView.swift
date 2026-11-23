import AVFoundation
import AVKit
import AppKit

/// A movie or a sound the viewer plays itself, with the system's player and its controls: it opens paused, Space plays
/// and pauses, and → and ← go forward and back five seconds. It stops when it shows another file or leaves the window,
/// so nothing plays out of sight.
final class ViewerMediaView: AVPlayerView {
    /// How far → and ← move.
    static let seekStep: Double = 5

    override init(frame: NSRect) {
        super.init(frame: frame)
        controlsStyle = .inline
        showsFullScreenToggleButton = true
        setAccessibilityIdentifier("textViewer.media")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Plays `url` from its start, paused; nil stops what played.
    func show(_ url: URL?) {
        player?.pause()
        player = url.map { AVPlayer(url: $0) }
    }

    var isPlaying: Bool { (player?.rate ?? 0) != 0 }

    /// Space: plays from where it is, from the start once it has ended.
    func togglePlaying() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            return
        }
        if let item = player.currentItem, item.duration.isNumeric,
            player.currentTime().seconds >= item.duration.seconds - 0.05
        {
            player.seek(to: .zero)
        }
        player.play()
    }

    /// → and ←: `seconds` forward or back, within the file.
    func seek(by seconds: Double) {
        guard let player else { return }
        var target = player.currentTime().seconds + seconds
        if let duration = player.currentItem?.duration, duration.isNumeric {
            target = min(target, duration.seconds)
        }
        player.seek(
            to: CMTime(seconds: max(0, target), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { player?.pause() }
        super.viewWillMove(toWindow: newWindow)
    }
}
