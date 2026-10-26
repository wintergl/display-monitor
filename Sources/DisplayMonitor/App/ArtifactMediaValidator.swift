import AVFoundation
import DisplayMonitorCore
import Foundation
import ImageIO

/// Keeps platform-specific decode validation outside the core persistence
/// actor. ArtifactStore still owns the recovery decision and manifest write.
enum ArtifactMediaValidator {
    static func validate(url: URL, kind: ArtifactKind) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return false
        }

        switch kind {
        case .recording:
            return validateVideo(url)
        case .still, .scrollStill, .gif, .revision:
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                return false
            }
            guard CGImageSourceGetCount(source) > 0 else { return false }
            // Use a bounded thumbnail for validation. Decoding a complete
            // 6K×30K scroll image just to verify it would violate the same
            // decoded-memory budget enforced by ScrollStitcher.
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 1_024,
                kCGImageSourceShouldCacheImmediately: true
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) != nil
        }
    }

    private static func validateVideo(_ url: URL) -> Bool {
        let validationURL: URL
        var compatibilityAlias: URL?
        if #available(macOS 14.0, *) {
            validationURL = url
        } else {
            let alias = url.deletingLastPathComponent().appendingPathComponent(
                ".validation-\(UUID().uuidString).mp4"
            )
            do {
                try FileManager.default.linkItem(at: url, to: alias)
                validationURL = alias
                compatibilityAlias = alias
            } catch {
                return false
            }
        }
        defer {
            if let compatibilityAlias {
                try? FileManager.default.removeItem(at: compatibilityAlias)
            }
        }
        let result = VideoValidationResult()
        let completed = DispatchSemaphore(value: 0)
        let task = Task.detached(priority: .utility) {
            defer { completed.signal() }
            // Recording writes to `artifact.mp4.tmp` until canonical commit.
            // Without an explicit MIME override AVFoundation guesses from the
            // final `.tmp` suffix and rejects an otherwise valid MP4.
            let asset: AVURLAsset
            if #available(macOS 14.0, *) {
                asset = AVURLAsset(
                    url: validationURL,
                    options: [AVURLAssetOverrideMIMETypeKey: "video/mp4"]
                )
            } else {
                asset = AVURLAsset(url: validationURL)
            }
            do {
                let playable = try await asset.load(.isPlayable)
                let videoTracks = try await asset.loadTracks(withMediaType: .video)
                result.set(playable && !videoTracks.isEmpty)
            } catch {
                result.set(false)
            }
        }
        guard completed.wait(timeout: .now() + 5) == .success else {
            task.cancel()
            return false
        }
        return result.value
    }
}

private final class VideoValidationResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func set(_ value: Bool) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }
}
