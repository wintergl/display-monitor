import AppKit
import DisplayMonitorCore
import ScreenCaptureKit

@MainActor
final class DisplayManager {
    func refreshDisplays() async -> [DisplayDescriptor] {
        let ids = onlineDisplayIDs()
        let shareableDisplays = await loadShareableDisplays()
        let shareableByID = Dictionary(uniqueKeysWithValues: shareableDisplays.map { ($0.displayID, $0) })

        return ids.map { displayID in
            let logicalBounds = CGDisplayBounds(displayID)
            let logicalSize = PixelSize(
                width: max(0, Int(logicalBounds.width.rounded())),
                height: max(0, Int(logicalBounds.height.rounded()))
            )
            let pixelSize = PixelSize(
                width: CGDisplayPixelsWide(displayID),
                height: CGDisplayPixelsHigh(displayID)
            )
            let name = displayName(for: displayID)
            let isMirrored = CGDisplayIsInMirrorSet(displayID) != 0 ||
                CGDisplayMirrorsDisplay(displayID) != kCGNullDirectDisplay
            let isBuiltin = CGDisplayIsBuiltin(displayID) != 0
            let isOnline = CGDisplayIsOnline(displayID) != 0
            let isActive = CGDisplayIsActive(displayID) != 0
            let availability = DisplayAvailabilityClassifier.classify(
                isOnline: isOnline,
                isActive: isActive,
                isMirrored: isMirrored,
                isShareable: shareableByID[displayID] != nil
            )

            let serial = CGDisplaySerialNumber(displayID)
            let identity = PersistentDisplayIdentity(
                vendorID: CGDisplayVendorNumber(displayID),
                modelID: CGDisplayModelNumber(displayID),
                serialNumber: serial == 0 ? nil : serial,
                localizedName: name,
                lastKnownPixelWidth: pixelSize.width,
                lastKnownPixelHeight: pixelSize.height,
                isBuiltin: isBuiltin
            )

            return DisplayDescriptor(
                id: displayID,
                localizedName: name,
                logicalSize: logicalSize,
                pixelSize: pixelSize,
                isPrimary: displayID == CGMainDisplayID(),
                isOnline: isOnline && isActive,
                isBuiltin: isBuiltin,
                isMirrored: isMirrored,
                captureAvailability: availability,
                persistentIdentity: identity
            )
        }
    }

    private func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        guard count > 0 else {
            return []
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    private func loadShareableDisplays() async -> [SCDisplay] {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            return content.displays
        } catch {
            return []
        }
    }

    private func displayName(for displayID: CGDirectDisplayID) -> String {
        if let screen = NSScreen.screens.first(where: { screen in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            return number?.uint32Value == displayID
        }) {
            return screen.localizedName
        }
        return "Display \(displayID)"
    }
}
