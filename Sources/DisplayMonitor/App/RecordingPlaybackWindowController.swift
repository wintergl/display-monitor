import AppKit
import AVFoundation
import AVKit

@MainActor
final class RecordingPlaybackWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    private let player: AVPlayer

    init(url: URL, title: String) {
        player = AVPlayer(url: url)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 760, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.minSize = CGSize(width: 520, height: 340)
        window.isReleasedWhenClosed = false

        let playerView = AVPlayerView(frame: window.contentView?.bounds ?? .zero)
        playerView.player = player
        playerView.controlsStyle = .floating
        playerView.showsFullScreenToggleButton = true
        playerView.videoGravity = .resizeAspect
        playerView.autoresizingMask = [.width, .height]
        window.contentView = playerView

        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        AppWindowActivation.activate()
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        player.play()
    }

    func windowWillClose(_ notification: Notification) {
        player.pause()
        onClose?()
    }
}
