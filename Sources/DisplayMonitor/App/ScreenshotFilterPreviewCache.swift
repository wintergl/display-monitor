import AppKit

/// View-only filter rasters. A missing preview must be covered with an opaque
/// placeholder by the caller, never with the unredacted source image.
@MainActor
final class ScreenshotFilterPreviewCache {
    struct Key: Hashable, Sendable {
        let stateID: UUID
        let nodeID: UUID
        let sourceRect: CGRect
        let level: Int

        init(stateID: UUID, nodeID: UUID, sourceRect: CGRect, level: Int) {
            self.stateID = stateID
            self.nodeID = nodeID
            self.sourceRect = sourceRect
            self.level = level
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.stateID == rhs.stateID && lhs.nodeID == rhs.nodeID
                && lhs.sourceRect == rhs.sourceRect && lhs.level == rhs.level
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(stateID)
            hasher.combine(nodeID)
            hasher.combine(sourceRect.origin.x)
            hasher.combine(sourceRect.origin.y)
            hasher.combine(sourceRect.width)
            hasher.combine(sourceRect.height)
            hasher.combine(level)
        }

        fileprivate var isValid: Bool {
            sourceRect.minX.isFinite && sourceRect.minY.isFinite
                && sourceRect.width.isFinite && sourceRect.height.isFinite
                && sourceRect.width > 0 && sourceRect.height > 0 && (0...30).contains(level)
        }
    }

    private struct Request: Sendable {
        let key: Key
        let producer: @Sendable () -> CGImage?
    }

    private struct Entry {
        let image: CGImage
        let cost: Int
        var access: UInt64
    }

    private struct Produced: @unchecked Sendable { let image: CGImage? }

    var onChange: (() -> Void)?
    let byteLimit: Int
    private var entries: [Key: Entry] = [:]
    private var frameRequests: [Key: Request] = [:]
    private var frameOrder: [Key] = []
    private var latestRequests: [Request] = []
    private var required: Set<Key> = []
    private var queue: [Request] = []
    private var failed: [Key: UInt64] = [:]
    private var capacityFailures: Set<Key> = []
    private var currentKey: Key?
    private var workTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var access: UInt64 = 0
    private var isSuspended = false
    private(set) var residentByteCount = 0
    private(set) var productionCount = 0
    var cachedImageCount: Int { entries.count }
    var pendingRequestCount: Int { queue.count }

    init(byteLimit: Int = 16 * 1_024 * 1_024) {
        self.byteLimit = max(4, byteLimit)
    }

    /// Collect one frame before replacing the old work queue. The caller may
    /// draw many visible blur/pixelate nodes inside this scope.
    func beginFrame() {
        frameRequests.removeAll(keepingCapacity: true)
        frameOrder.removeAll(keepingCapacity: true)
    }

    /// The producer must capture immutable render data and perform no AppKit
    /// view/text-input operations. It runs once on a background worker inside
    /// the shared raster gate. Its output must also have a bounded pixel size;
    /// the cache rejects an oversized result after production.
    func image(for key: Key, producer: @escaping @Sendable () -> CGImage?) -> CGImage? {
        guard key.isValid else { return nil }
        if frameRequests[key] == nil { frameOrder.append(key) }
        frameRequests[key] = Request(key: key, producer: producer)
        access &+= 1
        if entries[key] != nil {
            entries[key]?.access = access
            return entries[key]?.image
        }
        if failed[key] != nil { failed[key] = access }
        return nil
    }

    func endFrame() {
        latestRequests = frameOrder.compactMap { frameRequests[$0] }
        let visibleKeys = Set(frameOrder)
        if required != visibleKeys { capacityFailures.removeAll() }
        required = visibleKeys
        replaceQueue()
    }

    func setSuspended(_ suspended: Bool) {
        guard isSuspended != suspended else { return }
        isSuspended = suspended
        if suspended {
            cancelPendingRequests()
        } else {
            required = Set(latestRequests.map(\.key))
            replaceQueue()
        }
    }

    func cancelPendingRequests() {
        generation &+= 1
        queue = []
        required = []
    }

    func retryFailedRequests() {
        failed.removeAll()
        capacityFailures.removeAll()
    }

    func waitUntilIdle() async {
        while let task = workTask { await task.value }
    }

    private func replaceQueue() {
        queue = isSuspended ? [] : Array(latestRequests.lazy.filter { [self] in
            required.contains($0.key) && entries[$0.key] == nil && failed[$0.key] == nil
                && !capacityFailures.contains($0.key) && $0.key != currentKey
        }.prefix(64))
        if !isSuspended { startWorkIfNeeded() }
    }

    private func startWorkIfNeeded() {
        guard workTask == nil, !isSuspended, !queue.isEmpty else { return }
        let startedGeneration = generation
        workTask = Task { [weak self] in
            guard let self else { return }
            guard generation == startedGeneration, !isSuspended else {
                workTask = nil
                if !queue.isEmpty { startWorkIfNeeded() }
                return
            }
            while !isSuspended, !queue.isEmpty {
                let request = queue.removeFirst()
                guard required.contains(request.key), entries[request.key] == nil,
                      failed[request.key] == nil, !capacityFailures.contains(request.key) else { continue }
                currentKey = request.key
                let requestedGeneration = generation
                productionCount += 1
                let result = await Task.detached(priority: .userInitiated) {
                    ScreenshotRasterWorkGate.shared.withPermit {
                        autoreleasepool { Produced(image: request.producer()) }
                    }
                }.value
                currentKey = nil
                guard generation == requestedGeneration, required.contains(request.key), !isSuspended else { continue }
                guard let image = result.image else {
                    recordFailure(request.key)
                    continue
                }
                let (cost, overflow) = image.bytesPerRow.multipliedReportingOverflow(by: image.height)
                guard !overflow, cost <= byteLimit else {
                    recordFailure(request.key)
                    continue
                }
                // Keep current visible previews pinned. If all visible outputs
                // cannot fit together, retain opaque placeholders rather than
                // repeatedly evicting and regenerating one another each frame.
                while residentByteCount + cost > byteLimit,
                      let victim = entries.filter({ !required.contains($0.key) })
                        .min(by: { $0.value.access < $1.value.access })?.key {
                    residentByteCount -= entries.removeValue(forKey: victim)!.cost
                }
                guard residentByteCount + cost <= byteLimit else {
                    capacityFailures.insert(request.key)
                    continue
                }
                access &+= 1
                entries[request.key] = Entry(image: image, cost: cost, access: access)
                residentByteCount += cost
                onChange?()
            }
            workTask = nil
            if !isSuspended { replaceQueue() }
        }
    }

    private func recordFailure(_ key: Key) {
        access &+= 1
        failed[key] = access
        // Keep all visible failures stable; retire old document/zoom failures
        // so editing many documents cannot grow a permanent failure registry.
        while failed.count > 256,
              let victim = failed.filter({ !required.contains($0.key) }).min(by: { $0.value < $1.value })?.key {
            failed.removeValue(forKey: victim)
        }
    }
}
