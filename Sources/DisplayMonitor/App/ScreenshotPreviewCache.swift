import AppKit

/// A view-only raster pyramid. The source image is immutable and never changes
/// the editor document, undo stack, or text input view.
///
/// The byte limit applies to *additional* decoded preview rasters. The caller
/// still owns its original CGImage. Large PNG documents share a file-backed
/// raster source with export, so individual tiles do not decode the PNG again.
@MainActor
final class ScreenshotPreviewCache {
    struct Configuration {
        var tilePixelEdge: Int = 512
        var tileByteLimit: Int = 32 * 1_024 * 1_024
        var overviewPixelLimit: Int = 1_024 * 1_024
        var overviewDimensionLimit: Int = 2_048
        var maximumSourcePixels: Int = 200_000_000
        var maximumSourceDimension: Int = 120_000

        fileprivate var edge: Int { min(1_024, max(16, tilePixelEdge)) }
        fileprivate var budget: Int { max(edge * edge * 4, tileByteLimit) }
        fileprivate var overviewPixels: Int { max(1, overviewPixelLimit) }
        fileprivate var overviewDimension: Int { min(4_096, max(1, overviewDimensionLimit)) }
    }

    struct Tile {
        let image: CGImage
        /// Original image pixels, with the same top-left origin as the document.
        let sourceRect: CGRect
        /// Zero is original pixel resolution; each next level halves resolution.
        let level: Int
        let isOverview: Bool
    }

    private struct Key: Hashable {
        let level: Int
        let x: Int
        let y: Int
    }

    private struct Entry {
        let tile: Tile
        let byteCount: Int
        var access: UInt64
    }

    private struct Produced: @unchecked Sendable {
        let image: CGImage?
        var error: String? = nil
    }

    var onChange: (() -> Void)?
    let imageSize: CGSize
    let configuration: Configuration
    private let source: ScreenshotRasterSource
    private var entries: [Key: Entry] = [:]
    private var overview: Tile?
    private var required: Set<Key> = []
    private var queue: [Key] = []
    private var access: UInt64 = 0
    private var overviewWasRequested = false
    private var workTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var isSuspended = false
    private var latestRequest: (rect: CGRect, displayScale: CGFloat, backingScale: CGFloat)?
    private(set) var tileBytes = 0
    private(set) var productionCount = 0
    private(set) var requestedLevel = 0
    private(set) var failureMessage: String?
    let isSourceWithinBudget: Bool

    var cachedTileCount: Int { entries.count }
    var pendingTileCount: Int { queue.count }
    var residentByteCount: Int {
        tileBytes + (overview.map { $0.image.bytesPerRow * $0.image.height } ?? 0)
    }
    var maximumResidentByteCount: Int {
        configuration.budget + configuration.overviewPixels * 4
    }

    init(image: CGImage, sourceURL: URL? = nil, rasterSource: ScreenshotRasterSource? = nil,
         configuration: Configuration = Configuration()) {
        source = rasterSource ?? ScreenshotRasterSource(image: image, sourceURL: sourceURL)
        imageSize = CGSize(width: image.width, height: image.height)
        self.configuration = configuration
        let (pixels, overflow) = image.width.multipliedReportingOverflow(by: image.height)
        isSourceWithinBudget = !overflow && pixels <= configuration.maximumSourcePixels
            && max(image.width, image.height) <= configuration.maximumSourceDimension
    }

    /// Returns the already available overview followed by visible detail tiles.
    /// Missing detail is prepared serially off the main actor. Only the current
    /// visible region is queued, so fast panning cannot accumulate decode jobs.
    func tiles(for sourceRect: CGRect, displayScale: CGFloat, backingScale: CGFloat) -> [Tile] {
        guard isSourceWithinBudget, failureMessage == nil else { return [] }
        latestRequest = (sourceRect, displayScale, backingScale)
        let visible = sourceRect.intersection(CGRect(origin: .zero, size: imageSize))
        guard !visible.isNull, !visible.isEmpty,
              visible.minX.isFinite, visible.minY.isFinite,
              visible.width.isFinite, visible.height.isFinite,
              displayScale.isFinite, backingScale.isFinite,
              displayScale > 0, backingScale > 0 else {
            required = []
            queue = []
            return []
        }

        let pixelsPerSourcePixel = displayScale * backingScale
        let ideal = max(0, floor(-log2(max(pixelsPerSourcePixel, 1e-12))))
        var level = min(30, Int(ideal))
        var keys = keys(for: visible, level: level)
        let maximumVisible = max(1, configuration.budget / (configuration.edge * configuration.edge * 4))
        // An extraordinarily large viewport can require more native-resolution
        // tiles than the budget permits. Pick one coarser level in that case.
        while keys.count > maximumVisible, level < 30 {
            level += 1
            keys = self.keys(for: visible, level: level)
        }
        requestedLevel = level
        required = Set(keys)
        access &+= 1
        for key in keys where entries[key] != nil { entries[key]?.access = access }
        queue = isSuspended ? [] : keys.filter { entries[$0] == nil }
        if !isSuspended { startWorkIfNeeded() }

        var result = overview.map { [$0] } ?? []
        result.append(contentsOf: keys.compactMap { entries[$0]?.tile })
        return result
    }

    /// Used by fixture tests and callers that need an exact prepared preview.
    /// Interactive drawing should never wait for this.
    func waitUntilIdle() async {
        while let task = workTask { await task.value }
    }

    func removeCachedTiles() {
        cancelPendingRequests()
        entries.removeAll()
        tileBytes = 0
        overview = nil
        overviewWasRequested = false
    }

    /// An explicit save/copy attempt is also a retry boundary for temporary
    /// disk or decoder-service failures. Redrawing alone never retries them.
    func retryFailedRequests() {
        failureMessage = nil
        if overview == nil { overviewWasRequested = false }
    }

    /// Saving first suspends previews, then awaits waitUntilIdle off any native
    /// work. Existing rasters remain drawable without enqueueing more decodes.
    /// Resuming prepares only the last viewport requested while suspended.
    func setSuspended(_ suspended: Bool) {
        guard isSuspended != suspended else { return }
        isSuspended = suspended
        if suspended {
            cancelPendingRequests()
            if overview == nil { overviewWasRequested = false }
        } else if let request = latestRequest {
            _ = tiles(for: request.rect, displayScale: request.displayScale, backingScale: request.backingScale)
        }
    }

    /// A native draw already in progress may finish, but its result is discarded.
    /// At most one such draw exists; cancelled viewports never accumulate work.
    func cancelPendingRequests() {
        generation &+= 1
        queue = []
        required = []
        if overview == nil { overviewWasRequested = false }
    }

    private func keys(for rect: CGRect, level: Int) -> [Key] {
        let span = CGFloat(configuration.edge) * pow(2, CGFloat(level))
        let firstX = Int(floor(rect.minX / span))
        let firstY = Int(floor(rect.minY / span))
        let lastX = Int(floor(max(rect.minX, rect.maxX.nextDown) / span))
        let lastY = Int(floor(max(rect.minY, rect.maxY.nextDown) / span))
        // Compute a count before allocating; callers retry at a coarser level.
        let count = (lastX - firstX + 1) * (lastY - firstY + 1)
        let maximumVisible = max(1, configuration.budget / (configuration.edge * configuration.edge * 4))
        if count > maximumVisible {
            return Array(repeating: Key(level: level, x: firstX, y: firstY), count: maximumVisible + 1)
        }
        return (firstY...lastY).flatMap { y in
            (firstX...lastX).map { Key(level: level, x: $0, y: y) }
        }
    }

    private func rect(for key: Key) -> CGRect {
        let span = CGFloat(configuration.edge) * pow(2, CGFloat(key.level))
        return CGRect(x: CGFloat(key.x) * span, y: CGFloat(key.y) * span, width: span, height: span)
            .intersection(CGRect(origin: .zero, size: imageSize))
    }

    private func startWorkIfNeeded() {
        guard workTask == nil, !isSuspended else { return }
        let startedGeneration = generation
        workTask = Task { [weak self] in
            guard let self else { return }
            guard generation == startedGeneration else {
                workTask = nil
                if !queue.isEmpty { startWorkIfNeeded() }
                return
            }
            if !overviewWasRequested {
                overviewWasRequested = true
                let requestedGeneration = generation
                let fullRect = CGRect(origin: .zero, size: imageSize)
                let pixelScale = min(
                    1,
                    CGFloat(configuration.overviewDimension) / max(imageSize.width, imageSize.height),
                    sqrt(CGFloat(configuration.overviewPixels) / (imageSize.width * imageSize.height))
                )
                let produced = await makeRaster(rect: fullRect, scale: pixelScale)
                if let error = produced.error {
                    failureMessage = error
                    queue = []
                    workTask = nil
                    onChange?()
                    return
                }
                if generation == requestedGeneration, let image = produced.image {
                    overview = Tile(image: image, sourceRect: fullRect, level: 30, isOverview: true)
                    onChange?()
                }
            }
            while !queue.isEmpty {
                let key = queue.removeFirst()
                guard required.contains(key), entries[key] == nil else { continue }
                let sourceRect = rect(for: key)
                let requestedGeneration = generation
                let produced = await makeRaster(rect: sourceRect, scale: pow(0.5, CGFloat(key.level)))
                if let error = produced.error {
                    failureMessage = error
                    queue = []
                    break
                }
                guard generation == requestedGeneration, required.contains(key), let image = produced.image else { continue }
                let cost = image.bytesPerRow * image.height
                while tileBytes + cost > configuration.budget,
                      let victim = entries.min(by: { $0.value.access < $1.value.access })?.key {
                    tileBytes -= entries.removeValue(forKey: victim)!.byteCount
                }
                access &+= 1
                entries[key] = Entry(
                    tile: Tile(image: image, sourceRect: sourceRect, level: key.level, isOverview: false),
                    byteCount: cost, access: access
                )
                tileBytes += cost
                onChange?()
            }
            workTask = nil
            if failureMessage != nil { onChange?(); return }
            if !isSuspended, !overviewWasRequested, !required.isEmpty { startWorkIfNeeded() }
        }
    }

    private func makeRaster(rect: CGRect, scale: CGFloat) async -> Produced {
        let source = source
        productionCount += 1
        return await Task.detached(priority: .userInitiated) {
            ScreenshotRasterWorkGate.shared.withPermit { autoreleasepool {
                defer { source.releaseReadPages() }
                let image: CGImage
                do { image = try source.imageForRendering() }
                catch { return Produced(image: nil, error: "大图预览失败：\(error.localizedDescription)") }
                let width = max(1, Int(floor(rect.width * scale)))
                let height = max(1, Int(floor(rect.height * scale)))
                let colorSpace: CGColorSpace
                if let sourceSpace = image.colorSpace, sourceSpace.model == .rgb {
                    colorSpace = sourceSpace
                } else {
                    colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
                }
                guard let cropped = image.cropping(to: rect),
                      let context = CGContext(
                        data: nil, width: width, height: height,
                        bitsPerComponent: 8, bytesPerRow: width * 4,
                        space: colorSpace,
                        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                            | CGImageAlphaInfo.premultipliedLast.rawValue
                      ) else { return Produced(image: nil) }
                context.interpolationQuality = scale >= 1 ? .none : .high
                context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
                return Produced(image: context.makeImage())
            } }
        }.value
    }
}
