import CoreGraphics
import DisplayMonitorCore
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

struct MenuBarQuickBarCaptureGeometry: Equatable, Sendable {
    let displayID: CGDirectDisplayID
    let displayBounds: CGRect
    let globalStripRect: CGRect
    let sourceRect: CGRect
    let itemFrames: [String: CGRect]

    static func make(
        displayID: CGDirectDisplayID,
        displayBounds: CGRect,
        items: [MenuBarOrderItem]
    ) -> MenuBarQuickBarCaptureGeometry? {
        let validFrames = items.compactMap { item -> (String, CGRect)? in
            let frame = item.frame.intersection(displayBounds)
            guard !frame.isNull,
                  frame.width.isFinite,
                  frame.height.isFinite,
                  frame.width > 0,
                  frame.height > 0 else { return nil }
            return (item.id, frame)
        }
        guard !validFrames.isEmpty else { return nil }

        let strip = validFrames.dropFirst().reduce(validFrames[0].1) {
            $0.union($1.1)
        }.integral.intersection(displayBounds)
        guard !strip.isNull, strip.width > 0, strip.height > 0 else { return nil }
        return MenuBarQuickBarCaptureGeometry(
            displayID: displayID,
            displayBounds: displayBounds,
            globalStripRect: strip,
            sourceRect: CGRect(
                x: strip.minX - displayBounds.minX,
                y: strip.minY - displayBounds.minY,
                width: strip.width,
                height: strip.height
            ),
            itemFrames: Dictionary(uniqueKeysWithValues: validFrames)
        )
    }

    func pixelCropRect(for itemID: String, imageSize: CGSize) -> CGRect? {
        guard let itemFrame = itemFrames[itemID],
              imageSize.width.isFinite,
              imageSize.height.isFinite,
              imageSize.width > 0,
              imageSize.height > 0 else { return nil }
        let scaleX = imageSize.width / globalStripRect.width
        let scaleY = imageSize.height / globalStripRect.height
        let minX = floor((itemFrame.minX - globalStripRect.minX) * scaleX)
        let minY = floor((itemFrame.minY - globalStripRect.minY) * scaleY)
        let maxX = ceil((itemFrame.maxX - globalStripRect.minX) * scaleX)
        let maxY = ceil((itemFrame.maxY - globalStripRect.minY) * scaleY)
        let crop = CGRect(
            x: minX,
            y: minY,
            width: max(1, maxX - minX),
            height: max(1, maxY - minY)
        ).intersection(CGRect(origin: .zero, size: imageSize))
        return crop.isNull || crop.width <= 0 || crop.height <= 0 ? nil : crop
    }

    func pixelSize(pointPixelScale: CGFloat) -> (width: Int, height: Int) {
        let scale = pointPixelScale.isFinite && pointPixelScale > 0 ? pointPixelScale : 1
        return (
            max(1, Int(ceil(sourceRect.width * scale))),
            max(1, Int(ceil(sourceRect.height * scale)))
        )
    }
}

@MainActor
private final class MenuBarQuickBarIconCaptureCancellation {
    private(set) var isCancelled = false

    func cancel() {
        isCancelled = true
    }
}

/// A timed-out screenshot request can still be owned by ScreenCaptureKit. Keep
/// one registry marker until that native work actually replies, so a later
/// refresh cannot stack another request on top of it.
@MainActor
final class MenuBarQuickBarIconCaptureOperation {
    typealias Output = [String: MenuBarQuickBarIconSnapshot]
    typealias Work = @MainActor (
        _ shouldContinue: @escaping @MainActor () -> Bool
    ) async throws -> Output

    private let timeoutNanoseconds: UInt64
    private let requests = CaptureNativeRequestRegistry()

    init(timeoutNanoseconds: UInt64 = 1_750_000_000) {
        self.timeoutNanoseconds = timeoutNanoseconds
    }

    var canStart: Bool { requests.canStart }
    var pendingCount: Int { requests.pendingCount }

    func capture(
        onSettled: @escaping @MainActor () -> Void = {},
        operation: @escaping Work
    ) async -> Output {
        guard requests.canStart else {
            onSettled()
            return [:]
        }

        let requestID = requests.begin()
        let cancellation = MenuBarQuickBarIconCaptureCancellation()
        let deadline = CaptureNativeCallDeadline<Output>()
        var cancellationTimer: Task<Void, Never>?
        cancellationTimer = Task { @MainActor [weak cancellation] in
            do { try await Task.sleep(nanoseconds: timeoutNanoseconds) }
            catch { return }
            cancellation?.cancel()
        }

        return await withTaskCancellationHandler {
            do {
                return try await deadline.value(
                    timeoutNanoseconds: timeoutNanoseconds,
                    timeoutError: CaptureError(
                        code: "menu_bar_icon_capture_timeout",
                        message: "菜单栏图标快照采集超时"
                    ),
                    operation: {
                        try await operation { !cancellation.isCancelled }
                    },
                    // A caller which timed out or cancelled no longer owns the
                    // pixels. The late result is deliberately discarded.
                    onLateResult: { _ in },
                    onSettled: { [requests] in
                        cancellationTimer?.cancel()
                        requests.settle(requestID)
                        onSettled()
                    }
                )
            } catch {
                return [:]
            }
        } onCancel: {
            Task { @MainActor in cancellation.cancel() }
        }
    }
}

@MainActor
enum MenuBarQuickBarIconCapture {
    private static let nativeOperation = MenuBarQuickBarIconCaptureOperation()

    static var canStart: Bool { nativeOperation.canStart }
    static var pendingCount: Int { nativeOperation.pendingCount }

    static func capture(
        items: [MenuBarOrderItem],
        onSettled: @escaping @MainActor () -> Void = {}
    ) async -> [String: MenuBarQuickBarIconSnapshot] {
        guard !items.isEmpty,
              CGPreflightScreenCaptureAccess(),
              #available(macOS 14.0, *) else {
            onSettled()
            return [:]
        }

        return await nativeOperation.capture(onSettled: onSettled) { shouldContinue in
            try await capture(items: items, shouldContinue: shouldContinue)
        }
    }

    @available(macOS 14.0, *)
    private static func capture(
        items: [MenuBarOrderItem],
        shouldContinue: @escaping @MainActor () -> Bool
    ) async throws -> [String: MenuBarQuickBarIconSnapshot] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard shouldContinue() else { return [:] }
        let grouped = Dictionary(grouping: items, by: \.displayID)
        var snapshots: [String: MenuBarQuickBarIconSnapshot] = [:]
        for (displayID, displayItems) in grouped {
            guard shouldContinue(),
                  let display = content.displays.first(where: { $0.displayID == displayID }),
                  let geometry = MenuBarQuickBarCaptureGeometry.make(
                      displayID: displayID,
                      displayBounds: CGDisplayBounds(displayID),
                      items: displayItems
                  ) else { continue }
            do {
                let image = try await captureStrip(display: display, geometry: geometry)
                guard shouldContinue() else { return snapshots }
                snapshots.merge(
                    cropItems(image: image, geometry: geometry),
                    uniquingKeysWith: { _, latest in latest }
                )
            } catch {
                // Keep successful displays. Items from this display use the
                // existing application-icon fallback.
                continue
            }
        }
        return snapshots
    }

    @available(macOS 14.0, *)
    private static func captureStrip(
        display: SCDisplay,
        geometry: MenuBarQuickBarCaptureGeometry
    ) async throws -> CGImage {
        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: []
        )
        if #available(macOS 14.2, *) {
            filter.includeMenuBar = true
        }
        let pixelSize = geometry.pixelSize(
            pointPixelScale: CGFloat(filter.pointPixelScale)
        )
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = geometry.sourceRect
        configuration.width = pixelSize.width
        configuration.height = pixelSize.height
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        return try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
    }

    private static func cropItems(
        image: CGImage,
        geometry: MenuBarQuickBarCaptureGeometry
    ) -> [String: MenuBarQuickBarIconSnapshot] {
        let imageSize = CGSize(width: image.width, height: image.height)
        var snapshots: [String: MenuBarQuickBarIconSnapshot] = [:]
        for (itemID, frame) in geometry.itemFrames {
            guard let cropRect = geometry.pixelCropRect(for: itemID, imageSize: imageSize),
                  let crop = image.cropping(to: cropRect),
                  let pngData = pngData(for: crop) else { continue }
            snapshots[itemID] = MenuBarQuickBarIconSnapshot(
                pngData: pngData,
                pointSize: frame.size
            )
        }
        return snapshots
    }

    private static func pngData(for image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
