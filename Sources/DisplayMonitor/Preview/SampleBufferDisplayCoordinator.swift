import AVFoundation
import Combine
import CoreMedia
import os

/// A capture callback may replace the waiting frame, but never queues another
/// drain while one is pending. The lock also owns frames that are not Sendable;
/// no mutable CoreMedia state is accessed outside its producer/consumer boundary.
final class LatestPreviewFrameMailbox<Frame>: Sendable {
    private struct State {
        var epoch: UInt64 = 0
        var frame: Frame?
        var frameCount = 0
        var drainScheduled = false
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    var epoch: UInt64 { state.withLockUnchecked { $0.epoch } }

    /// Returns true only when the caller must schedule one main-queue drain.
    func offer(_ frame: Frame, epoch: UInt64) -> Bool {
        state.withLockUnchecked { state in
            guard epoch == state.epoch else { return false }
            state.frame = frame
            state.frameCount &+= 1
            guard !state.drainScheduled else { return false }
            state.drainScheduled = true
            return true
        }
    }

    func takeForDrain() -> Frame? {
        takeBatchForDrain()?.frame
    }

    func takeBatchForDrain() -> (frame: Frame, count: Int)? {
        state.withLockUnchecked { state in
            defer {
                state.frame = nil
                state.frameCount = 0
                state.drainScheduled = false
            }
            guard let frame = state.frame else { return nil }
            return (frame, state.frameCount)
        }
    }

    func invalidate() {
        state.withLockUnchecked { state in
            state.epoch &+= 1
            state.frame = nil
            state.frameCount = 0
            // Preserve an already scheduled drain: it can consume the next
            // epoch's frame and prevents flush/start bursts queuing callbacks.
        }
    }
}

@MainActor
final class SampleBufferDisplayCoordinator: ObservableObject {
    private struct PendingFrame {
        let sampleBuffer: CMSampleBuffer
        let onFrame: @MainActor @Sendable (Int) -> Void
    }

    private weak var displayLayer: AVSampleBufferDisplayLayer?
    nonisolated private let mailbox = LatestPreviewFrameMailbox<PendingFrame>()

    var frameEpoch: UInt64 { mailbox.epoch }

    func attach(_ layer: AVSampleBufferDisplayLayer) {
        displayLayer = layer
        layer.videoGravity = .resizeAspect
    }

    nonisolated func enqueue(
        _ sampleBuffer: CMSampleBuffer,
        epoch: UInt64,
        onFrame: @escaping @MainActor @Sendable (Int) -> Void
    ) {
        // ScreenCaptureKit gives us read-only complete frames. Retain only the
        // latest buffer; neither this path nor the main consumer mutate it.
        guard mailbox.offer(PendingFrame(sampleBuffer: sampleBuffer, onFrame: onFrame), epoch: epoch) else { return }
        DispatchQueue.main.async { [weak self] in self?.drain() }
    }

    private func drain() {
        guard let batch = mailbox.takeBatchForDrain() else { return }
        let frame = batch.frame
        frame.onFrame(batch.count)
        let sampleBuffer = frame.sampleBuffer
        guard let displayLayer else {
            return
        }
        if displayLayer.status == .failed {
            displayLayer.flush()
        }
        if displayLayer.isReadyForMoreMediaData {
            displayLayer.enqueue(sampleBuffer)
        } else {
            displayLayer.flush()
            displayLayer.enqueue(sampleBuffer)
        }
    }

    func flush() {
        mailbox.invalidate()
        displayLayer?.flush()
    }
}
