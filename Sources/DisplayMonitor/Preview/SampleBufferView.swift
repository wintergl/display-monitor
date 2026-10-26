import AVFoundation
import SwiftUI

struct SampleBufferView: NSViewRepresentable {
    let coordinator: SampleBufferDisplayCoordinator

    func makeNSView(context: Context) -> SampleBufferHostView {
        let view = SampleBufferHostView()
        coordinator.attach(view.sampleLayer)
        return view
    }

    func updateNSView(_ nsView: SampleBufferHostView, context: Context) {
        coordinator.attach(nsView.sampleLayer)
    }
}

final class SampleBufferHostView: NSView {
    let sampleLayer = AVSampleBufferDisplayLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayer()
    }

    private func configureLayer() {
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        sampleLayer.videoGravity = .resizeAspect
        layer?.addSublayer(sampleLayer)
    }

    override func layout() {
        super.layout()
        sampleLayer.frame = bounds
    }
}
