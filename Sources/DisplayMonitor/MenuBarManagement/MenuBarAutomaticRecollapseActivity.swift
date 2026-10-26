import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

struct MenuBarAutomaticRecollapseActivitySnapshot: Equatable, Sendable {
    let isReadable: Bool
    let pointerInsideMenuBar: Bool
    let hasPressedMouseButtons: Bool
    let hasOpenMenuOrPopover: Bool
    let diagnostics: MenuBarAutomaticRecollapseActivityDiagnostics

    init(
        isReadable: Bool,
        pointerInsideMenuBar: Bool,
        hasPressedMouseButtons: Bool,
        hasOpenMenuOrPopover: Bool,
        diagnostics: MenuBarAutomaticRecollapseActivityDiagnostics = .init()
    ) {
        self.isReadable = isReadable
        self.pointerInsideMenuBar = pointerInsideMenuBar
        self.hasPressedMouseButtons = hasPressedMouseButtons
        self.hasOpenMenuOrPopover = hasOpenMenuOrPopover
        self.diagnostics = diagnostics
    }

    var deferralSignature: MenuBarAutomaticRecollapseDeferralSignature {
        MenuBarAutomaticRecollapseDeferralSignature(
            isReadable: isReadable,
            pointerInsideMenuBar: pointerInsideMenuBar,
            hasPressedMouseButtons: hasPressedMouseButtons,
            hasOpenMenuOrPopover: hasOpenMenuOrPopover,
            blockingClassifications: diagnostics.blockingClassifications
        )
    }
}

/// Stable automatic-recollapse state used for log de-duplication. Counts for
/// ordinary and explicitly excluded windows never enter this signature.
struct MenuBarAutomaticRecollapseDeferralSignature: Equatable, Sendable {
    let isReadable: Bool
    let pointerInsideMenuBar: Bool
    let hasPressedMouseButtons: Bool
    let hasOpenMenuOrPopover: Bool
    let blockingClassifications: [MenuBarAutomaticRecollapseWindowClassification: Int]
}

enum MenuBarAutomaticRecollapseWindowClassification: String, CaseIterable, Hashable, Sendable {
    case popupMenuLayer
    case topMainMenuLayer
    case topStatusWindowLayer
    case topOtherElevatedLayer
    case notificationCenterExcluded
    case notificationCenterPanel
    case menuBarBackgroundExcluded
    case nonTopElevatedExcluded
    case normalOrBelowExcluded
    case incompleteMetadata
}

/// Aggregate-only evidence from the same CGWindow sample used for the activity
/// decision. Fixed keys and counts intentionally exclude process identity,
/// window titles, raw layers, and geometry.
struct MenuBarAutomaticRecollapseActivityDiagnostics: Equatable, Sendable {
    let windowCount: Int
    let completeWindowCount: Int
    let classifications: [MenuBarAutomaticRecollapseWindowClassification: Int]

    init(
        windowCount: Int = 0,
        completeWindowCount: Int = 0,
        classifications: [MenuBarAutomaticRecollapseWindowClassification: Int] = [:]
    ) {
        self.windowCount = max(0, windowCount)
        self.completeWindowCount = max(0, min(completeWindowCount, windowCount))
        self.classifications = classifications.filter { $0.value > 0 }
    }

    var blockingClassifications: [MenuBarAutomaticRecollapseWindowClassification: Int] {
        let blockingKeys: Set<MenuBarAutomaticRecollapseWindowClassification> = [
            .popupMenuLayer, .topMainMenuLayer, .topStatusWindowLayer, .topOtherElevatedLayer,
            .notificationCenterPanel,
        ]
        return classifications.filter { blockingKeys.contains($0.key) }
    }

    var blockingWindowCount: Int {
        blockingClassifications.values.reduce(0, +)
    }

    var blockingSummary: String {
        let classes = blockingClassifications
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key.rawValue)=\($0.value)" }
            .joined(separator: ",")
        let classificationSummary = classes.isEmpty ? "none" : classes
        return "blockers=\(blockingWindowCount),classes=\(classificationSummary)"
    }

    var summary: String {
        let classes = classifications
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key.rawValue)=\($0.value)" }
            .joined(separator: ",")
        let classificationSummary = classes.isEmpty ? "none" : classes
        return "windows=\(windowCount),complete=\(completeWindowCount),blockers=\(blockingWindowCount),classes=\(classificationSummary)"
    }
}

struct MenuBarAutomaticRecollapseWindowMetadata: Equatable, Sendable {
    let ownerPID: Int32?
    let layer: Int?
    let bounds: CGRect?
}

private struct MenuBarAutomaticRecollapseCGRead: Sendable {
    let displayBounds: [CGRect]?
    let windows: [MenuBarAutomaticRecollapseWindowMetadata]?
}

enum MenuBarAutomaticRecollapseActivityClassifier {
    static func classify(
        pointer: CGPoint,
        pressedMouseButtons: Int,
        appKitDisplayFrames: [CGRect],
        cgDisplayBounds: [CGRect]?,
        windows: [MenuBarAutomaticRecollapseWindowMetadata]?,
        notificationCenterProcessIdentifiers: Set<Int32> = [],
        notificationCenterHasOpenPanel: Bool = false,
        menuBarHeight: CGFloat = 40,
        popUpMenuLayer: Int = Int(CGWindowLevelForKey(.popUpMenuWindow)),
        normalWindowLayer: Int = Int(CGWindowLevelForKey(.normalWindow)),
        mainMenuWindowLayer: Int = Int(CGWindowLevelForKey(.mainMenuWindow)),
        statusWindowLayer: Int = Int(CGWindowLevelForKey(.statusWindow))
    ) -> MenuBarAutomaticRecollapseActivitySnapshot {
        let hasPressedMouseButtons = pressedMouseButtons != 0
        let pointerIsFinite = pointer.x.isFinite && pointer.y.isFinite
        let displayFramesAreValid = !appKitDisplayFrames.isEmpty
            && appKitDisplayFrames.allSatisfy(validRect)
        let pointerInsideMenuBar = pointerIsFinite && displayFramesAreValid
            && appKitDisplayFrames.contains { display in
                pointer.x >= display.minX && pointer.x <= display.maxX
                    && pointer.y >= display.maxY - menuBarHeight
                    && pointer.y <= display.maxY + 1
            }

        guard pointerIsFinite,
              pressedMouseButtons >= 0,
              menuBarHeight > 0,
              menuBarHeight.isFinite,
              displayFramesAreValid,
              let cgDisplayBounds,
              !cgDisplayBounds.isEmpty,
              cgDisplayBounds.allSatisfy(validRect),
              let windows,
              !windows.isEmpty else {
            return MenuBarAutomaticRecollapseActivitySnapshot(
                isReadable: false,
                pointerInsideMenuBar: pointerInsideMenuBar,
                hasPressedMouseButtons: hasPressedMouseButtons,
                hasOpenMenuOrPopover: false,
                diagnostics: MenuBarAutomaticRecollapseActivityDiagnostics(
                    windowCount: windows?.count ?? 0,
                    completeWindowCount: 0,
                    classifications: [:]
                )
            )
        }

        var completeWindows: [(ownerPID: Int32, layer: Int, bounds: CGRect)] = []
        completeWindows.reserveCapacity(windows.count)
        var classifications: [MenuBarAutomaticRecollapseWindowClassification: Int] = [:]
        for window in windows {
            guard let ownerPID = window.ownerPID, ownerPID > 0,
                  let layer = window.layer,
                  let bounds = window.bounds,
                  validRect(bounds) else {
                classifications[.incompleteMetadata, default: 0] += 1
                continue
            }
            completeWindows.append((ownerPID, layer, bounds))
        }

        guard completeWindows.count == windows.count else {
            return MenuBarAutomaticRecollapseActivitySnapshot(
                isReadable: false,
                pointerInsideMenuBar: pointerInsideMenuBar,
                hasPressedMouseButtons: hasPressedMouseButtons,
                hasOpenMenuOrPopover: false,
                diagnostics: MenuBarAutomaticRecollapseActivityDiagnostics(
                    windowCount: windows.count,
                    completeWindowCount: completeWindows.count,
                    classifications: classifications
                )
            )
        }

        var hasOpenMenuOrPopover = notificationCenterHasOpenPanel
        if notificationCenterHasOpenPanel {
            classifications[.notificationCenterPanel] = 1
        }
        for window in completeWindows {
            if window.layer == popUpMenuLayer {
                classifications[.popupMenuLayer, default: 0] += 1
                hasOpenMenuOrPopover = true
                continue
            }
            guard window.layer > normalWindowLayer else {
                classifications[.normalOrBelowExcluded, default: 0] += 1
                continue
            }
            var matchesMenuBarBackground = false
            let blocksAsTopElevatedWindow = cgDisplayBounds.contains { display in
                let overlapsHorizontally = window.bounds.maxX > display.minX
                    && window.bounds.minX < display.maxX
                let beginsNearTop = window.bounds.minY >= display.minY - 1
                    && window.bounds.minY <= display.minY + menuBarHeight
                let extendsBelowMenuBar = window.bounds.maxY > display.minY + menuBarHeight
                let isMenuBarBackgroundLayer = window.layer == mainMenuWindowLayer
                    || window.layer == statusWindowLayer
                let isTopAlignedWideBar = abs(window.bounds.minY - display.minY) <= 1
                    && window.bounds.width >= display.width / 2
                    && window.bounds.height <= 80
                if isMenuBarBackgroundLayer && isTopAlignedWideBar {
                    matchesMenuBarBackground = true
                    return false
                }
                return overlapsHorizontally && beginsNearTop && extendsBelowMenuBar
            }
            guard blocksAsTopElevatedWindow else {
                let classification: MenuBarAutomaticRecollapseWindowClassification =
                    matchesMenuBarBackground
                    ? .menuBarBackgroundExcluded
                    : .nonTopElevatedExcluded
                classifications[classification, default: 0] += 1
                continue
            }

            let classification: MenuBarAutomaticRecollapseWindowClassification
            if window.layer == mainMenuWindowLayer {
                classification = .topMainMenuLayer
            } else if window.layer == statusWindowLayer {
                classification = .topStatusWindowLayer
            } else if notificationCenterProcessIdentifiers.contains(window.ownerPID) {
                classifications[.notificationCenterExcluded, default: 0] += 1
                continue
            } else {
                classification = .topOtherElevatedLayer
            }
            classifications[classification, default: 0] += 1
            hasOpenMenuOrPopover = true
        }

        return MenuBarAutomaticRecollapseActivitySnapshot(
            isReadable: true,
            pointerInsideMenuBar: pointerInsideMenuBar,
            hasPressedMouseButtons: hasPressedMouseButtons,
            hasOpenMenuOrPopover: hasOpenMenuOrPopover,
            diagnostics: MenuBarAutomaticRecollapseActivityDiagnostics(
                windowCount: windows.count,
                completeWindowCount: completeWindows.count,
                classifications: classifications
            )
        )
    }

    private static func validRect(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.width.isFinite && rect.height.isFinite
            && rect.width > 0 && rect.height > 0
    }
}

@MainActor
enum MenuBarAutomaticRecollapseActivity {
    private static let notificationCenterBundleIdentifier = "com.apple.notificationcenterui"

    static func read() async -> MenuBarAutomaticRecollapseActivitySnapshot {
        let pointer = NSEvent.mouseLocation
        let pressedMouseButtons = NSEvent.pressedMouseButtons
        let appKitDisplayFrames = NSScreen.screens.map(\.frame)
        // Resolve exact process instances, never exempt a window by its name.
        let notificationCenterProcessIdentifiers = Set(
            NSWorkspace.shared.runningApplications.compactMap { application -> Int32? in
                guard application.bundleIdentifier == notificationCenterBundleIdentifier,
                      application.processIdentifier > 0 else { return nil }
                return application.processIdentifier
            }
        )
        let (cgRead, hasOpenPanel) = await MenuBarCollapseRuntime.performDetachedRead(priority: .utility) {
            (readCGWindowMetadata(), notificationCenterProcessIdentifiers.contains { pid in
                notificationCenterHasOpenPanel(pid: pid)
            })
        }
        return MenuBarAutomaticRecollapseActivityClassifier.classify(
            pointer: pointer,
            pressedMouseButtons: pressedMouseButtons,
            appKitDisplayFrames: appKitDisplayFrames,
            cgDisplayBounds: cgRead.displayBounds,
            windows: cgRead.windows,
            notificationCenterProcessIdentifiers: notificationCenterProcessIdentifiers.intersection(Set(
                NSWorkspace.shared.runningApplications.filter {
                    $0.bundleIdentifier == notificationCenterBundleIdentifier
                }.map(\.processIdentifier)
            )),
            notificationCenterHasOpenPanel: hasOpenPanel
        )
    }

    /// Desktop widgets and the persistent full-screen backdrop are not an open
    /// Notification Center. Its actual panel is an AX system dialog. Read only
    /// that subrole; notification contents never enter our state or diagnostics.
    private nonisolated static func notificationCenterHasOpenPanel(pid: Int32) -> Bool {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.05)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value)
        if result == .noValue { return false }
        guard result == .success, let windows = value as? [AXUIElement] else { return true }
        for window in windows {
            var subrole: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subrole)
            // Desktop widget windows need not expose a subrole at all.
            if status == .attributeUnsupported || status == .noValue { continue }
            guard status == .success, let subrole = subrole as? String else { return true }
            if subrole == kAXSystemDialogSubrole { return true }
        }
        return false
    }

    private nonisolated static func readCGWindowMetadata() -> MenuBarAutomaticRecollapseCGRead {
        var displayCount: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &displayCount) == .success,
              displayCount > 0 else {
            return MenuBarAutomaticRecollapseCGRead(displayBounds: nil, windows: nil)
        }
        var displays = Array(repeating: CGDirectDisplayID(), count: Int(displayCount))
        guard CGGetOnlineDisplayList(displayCount, &displays, &displayCount) == .success else {
            return MenuBarAutomaticRecollapseCGRead(displayBounds: nil, windows: nil)
        }
        let displayBounds = displays.prefix(Int(displayCount)).map(CGDisplayBounds)
        guard !displayBounds.isEmpty,
              let rawWindows = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
              ) as? [[String: Any]] else {
            return MenuBarAutomaticRecollapseCGRead(displayBounds: displayBounds, windows: nil)
        }

        let windows = rawWindows.map { dictionary in
            MenuBarAutomaticRecollapseWindowMetadata(
                ownerPID: (dictionary[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                layer: (dictionary[kCGWindowLayer as String] as? NSNumber)?.intValue,
                bounds: (dictionary[kCGWindowBounds as String] as? NSDictionary)
                    .flatMap { CGRect(dictionaryRepresentation: $0) }
            )
        }
        return MenuBarAutomaticRecollapseCGRead(displayBounds: displayBounds, windows: windows)
    }
}
