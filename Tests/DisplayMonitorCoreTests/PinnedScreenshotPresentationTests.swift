import AppKit
import DisplayMonitorCore
import XCTest
@testable import DisplayMonitor

final class PinnedScreenshotPresentationTests: XCTestCase {
    func testAbsoluteScaleRestoresInitialSizeWithoutAccumulatingRounding() {
        let initial = CGRect(x: 100, y: 200, width: 320, height: 180)
        let screen = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let doubled = PinnedScreenshotPlacement.scaledFrame(
            initialSize: initial.size, scale: 2, currentFrame: initial, visibleFrame: screen
        )
        XCTAssertEqual(doubled.size, CGSize(width: 640, height: 360))
        XCTAssertEqual(doubled.midX, initial.midX)
        XCTAssertEqual(doubled.midY, initial.midY)
        let restored = PinnedScreenshotPlacement.scaledFrame(
            initialSize: initial.size, scale: 1, currentFrame: doubled, visibleFrame: screen
        )
        XCTAssertEqual(restored, initial)
        let half = PinnedScreenshotPlacement.scaledFrame(
            initialSize: initial.size, scale: 0.5, currentFrame: doubled, visibleFrame: screen
        )
        XCTAssertEqual(half.size, CGSize(width: 160, height: 90))
    }

    func testScaledPinRemainsReachableOnNegativeOriginDisplay() throws {
        let screen = CGRect(x: -1_920, y: -100, width: 1_920, height: 1_080)
        let old = CGRect(x: 2_000, y: -2_000, width: 500, height: 300)
        let scaled = PinnedScreenshotPlacement.scaledFrame(
            initialSize: old.size, scale: 4, currentFrame: old, visibleFrame: screen
        )
        XCTAssertEqual(scaled.size, CGSize(width: 2_000, height: 1_200))
        let visible = scaled.intersection(screen)
        XCTAssertGreaterThanOrEqual(visible.width, 24)
        XCTAssertGreaterThanOrEqual(visible.height, 24)
        let target = try XCTUnwrap(PinnedScreenshotPlacement.preferredVisibleFrame(
            for: scaled, among: [CGRect(x: 0, y: 0, width: 1_440, height: 900), screen]
        ))
        XCTAssertEqual(target, screen)
    }

    func testInvalidScaleDoesNotMoveOrResizePin() {
        let current = CGRect(x: 20, y: 30, width: 200, height: 100)
        for scale in [Double.nan, .infinity, 0, -1] {
            XCTAssertEqual(PinnedScreenshotPlacement.scaledFrame(
                initialSize: current.size, scale: scale, currentFrame: current,
                visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800)
            ), current)
        }
    }

    @MainActor
    func testPinMenuExposesAbsoluteScaleOpacityAndOriginalFileActions() throws {
        _ = NSApplication.shared
        var scales: [Double] = []
        var opacities: [Double] = []
        var copies = 0
        var saves = 0
        var closeAll = 0
        let view = PinnedScreenshotContentView(
            image: NSImage(size: CGSize(width: 320, height: 180)),
            onCopy: { copies += 1 }, onSave: { saves += 1 }, onClose: {},
            onCloseAll: { closeAll += 1 }, onScale: { scales.append($0) },
            onOpacity: { opacities.append($0) }
        )
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 180)
        view.setPresentation(scale: 2, opacity: 0.5)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        let menu = try XCTUnwrap(view.menu(for: event))
        let scaleMenu = try XCTUnwrap(menu.items.first { $0.title == "倍率（相对初始尺寸）" }?.submenu)
        XCTAssertEqual(scaleMenu.items.first { $0.title == "200%" }?.state, .on)
        let half = try XCTUnwrap(scaleMenu.items.first { $0.title == "50%" })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(half.action), to: half.target, from: half))
        let reset = try XCTUnwrap(menu.items.first { $0.title == "恢复初始尺寸" })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(reset.action), to: reset.target, from: reset))
        let opacityMenu = try XCTUnwrap(menu.items.first { $0.title == "不透明度" }?.submenu)
        XCTAssertEqual(opacityMenu.items.first { $0.title == "50%" }?.state, .on)
        let quarter = try XCTUnwrap(opacityMenu.items.first { $0.title == "25%" })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(quarter.action), to: quarter.target, from: quarter))
        XCTAssertEqual(scales, [0.5, 1])
        XCTAssertEqual(opacities, [0.25])
        // Presentation changes never invoke any copy/save operation.
        XCTAssertEqual(copies, 0)
        XCTAssertEqual(saves, 0)
        XCTAssertEqual(closeAll, 0)
        for title in ["复制图片", "保存到设定位置", "关闭全部贴图"] {
            let item = try XCTUnwrap(menu.items.first { $0.title == title })
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        }
        XCTAssertEqual(copies, 1)
        XCTAssertEqual(saves, 1)
        XCTAssertEqual(closeAll, 1)
    }
}
