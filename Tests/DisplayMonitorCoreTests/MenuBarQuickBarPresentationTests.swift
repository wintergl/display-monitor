import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import DisplayMonitor

@MainActor
final class MenuBarQuickBarPresentationTests: XCTestCase {
    func testCompactSingleRowVisualFixtureUsesNativePointSizes() throws {
        _ = NSApplication.shared
        let compactSnapshot = try symbolSnapshot(
            name: "bolt.fill",
            pointSize: CGSize(width: 16, height: 16)
        )
        let standardSnapshot = try symbolSnapshot(
            name: "wifi",
            pointSize: CGSize(width: 22, height: 22)
        )
        let wideSnapshot = try wideStatusSnapshot(
            text: "VPN 42%",
            pointSize: CGSize(width: 112, height: 22)
        )
        let snapshots = [compactSnapshot, standardSnapshot, wideSnapshot]
        let items = [
            item(id: "power", name: "电源", snapshot: compactSnapshot),
            item(id: "network", name: "网络", snapshot: standardSnapshot),
            item(id: "vpn", name: "VPN 42%", snapshot: wideSnapshot),
        ]
        let model = MenuBarQuickBarModel()
        model.update(items: items) { _ in }

        let width = MenuBarQuickBarLayoutPolicy.panelWidth(
            snapshotPointSizes: snapshots.map(\.pointSize),
            maximumWidth: 900
        )
        let compactMetrics = MenuBarQuickBarLayoutPolicy.itemMetrics(
            snapshotPointSize: compactSnapshot.pointSize
        )
        let wideMetrics = MenuBarQuickBarLayoutPolicy.itemMetrics(
            snapshotPointSize: wideSnapshot.pointSize
        )
        XCTAssertEqual(MenuBarQuickBarLayoutPolicy.panelHeight, 40)
        XCTAssertEqual(compactMetrics.iconSize, compactSnapshot.pointSize)
        XCTAssertEqual(wideMetrics.iconSize, wideSnapshot.pointSize)
        XCTAssertEqual(wideMetrics.itemWidth, 120)
        XCTAssertGreaterThan(wideMetrics.itemWidth, compactMetrics.itemWidth)

        let hostingView = NSHostingView(rootView: MenuBarQuickBarView(model: model))
        hostingView.frame = CGRect(
            origin: .zero,
            size: CGSize(width: width, height: MenuBarQuickBarLayoutPolicy.panelHeight)
        )
        hostingView.appearance = NSAppearance(named: .aqua)
        hostingView.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertFalse(png.isEmpty)
        XCTAssertEqual(hostingView.bounds.height, 40)

        guard let outputPath = ProcessInfo.processInfo.environment[
            "DISPLAY_MONITOR_VISUAL_FIXTURE_DIR"
        ] else { return }
        let directory = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try png.write(
            to: directory.appendingPathComponent("menu-bar-quick-bar-compact.png")
        )
    }

    func testSearchAndReorderDraftVisualFixturesStayInOneCompactRow() throws {
        _ = NSApplication.shared
        let compactSnapshot = try symbolSnapshot(
            name: "bolt.fill",
            pointSize: CGSize(width: 16, height: 16)
        )
        let standardSnapshot = try symbolSnapshot(
            name: "wifi",
            pointSize: CGSize(width: 22, height: 22)
        )
        let wideSnapshot = try wideStatusSnapshot(
            text: "VPN 42%",
            pointSize: CGSize(width: 112, height: 22)
        )
        let items = [
            item(id: "power", name: "电源", snapshot: compactSnapshot),
            item(id: "network", name: "网络", snapshot: standardSnapshot),
            item(id: "vpn", name: "VPN 42%", snapshot: wideSnapshot),
        ]
        let pointSizes = items.map { $0.iconSnapshot?.pointSize }
        let model = MenuBarQuickBarModel()
        model.update(items: items) { _ in }

        model.openSearch()
        model.setSearchQuery("VPN")
        let searchPNG = try render(
            model: model,
            width: MenuBarQuickBarLayoutPolicy.panelWidth(
                snapshotPointSizes: pointSizes,
                maximumWidth: 900,
                isSearchVisible: true
            )
        )
        XCTAssertFalse(searchPNG.isEmpty)
        XCTAssertEqual(model.visibleItems.map(\.id), ["vpn"])

        model.closeSearch()
        let token = try XCTUnwrap(model.beginDragging(itemID: "vpn"))
        XCTAssertTrue(model.acceptDrop(
            token: token,
            relativeTo: "power",
            placement: .before
        ))
        let draftPNG = try render(
            model: model,
            width: MenuBarQuickBarLayoutPolicy.panelWidth(
                snapshotPointSizes: pointSizes,
                maximumWidth: 900,
                hasReorderDraft: true
            )
        )
        XCTAssertFalse(draftPNG.isEmpty)
        XCTAssertEqual(model.items.map(\.id), ["vpn", "power", "network"])

        guard let outputPath = ProcessInfo.processInfo.environment[
            "DISPLAY_MONITOR_VISUAL_FIXTURE_DIR"
        ] else { return }
        let directory = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try searchPNG.write(
            to: directory.appendingPathComponent("menu-bar-quick-bar-search.png")
        )
        try draftPNG.write(
            to: directory.appendingPathComponent("menu-bar-quick-bar-reorder-draft.png")
        )
    }

    private func render(
        model: MenuBarQuickBarModel,
        width: CGFloat
    ) throws -> Data {
        let hostingView = NSHostingView(rootView: MenuBarQuickBarView(model: model))
        hostingView.frame = CGRect(
            origin: .zero,
            size: CGSize(width: width, height: MenuBarQuickBarLayoutPolicy.panelHeight)
        )
        hostingView.appearance = NSAppearance(named: .aqua)
        hostingView.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    private func item(
        id: String,
        name: String,
        snapshot: MenuBarQuickBarIconSnapshot
    ) -> MenuBarQuickBarItem {
        MenuBarQuickBarItem(
            id: id,
            bundleIdentifier: "fixture.\(id)",
            applicationName: name,
            itemTitle: name,
            processIdentifier: 1,
            iconSnapshot: snapshot
        )
    }

    private func symbolSnapshot(
        name: String,
        pointSize: CGSize
    ) throws -> MenuBarQuickBarIconSnapshot {
        let source = try XCTUnwrap(NSImage(
            systemSymbolName: name,
            accessibilityDescription: nil
        ))
        let configured = source.withSymbolConfiguration(
            .init(pointSize: min(16, pointSize.height), weight: .medium)
        ) ?? source
        return try snapshot(pointSize: pointSize) { bounds in
            let side = min(configured.size.width, configured.size.height, bounds.height)
            configured.draw(
                in: CGRect(
                    x: bounds.midX - side / 2,
                    y: bounds.midY - side / 2,
                    width: side,
                    height: side
                )
            )
        }
    }

    private func wideStatusSnapshot(
        text: String,
        pointSize: CGSize
    ) throws -> MenuBarQuickBarIconSnapshot {
        let symbol = try XCTUnwrap(NSImage(
            systemSymbolName: "lock.shield.fill",
            accessibilityDescription: nil
        ))
        return try snapshot(pointSize: pointSize) { bounds in
            symbol.draw(in: CGRect(x: 2, y: 3, width: 16, height: 16))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.labelColor,
            ]
            NSAttributedString(string: text, attributes: attributes).draw(
                at: CGPoint(x: 22, y: 4)
            )
        }
    }

    private func snapshot(
        pointSize: CGSize,
        draw: @escaping (CGRect) -> Void
    ) throws -> MenuBarQuickBarIconSnapshot {
        let image = NSImage(size: pointSize, flipped: false) { bounds in
            draw(bounds)
            return true
        }
        let representation = try XCTUnwrap(
            NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))
        )
        let png = try XCTUnwrap(representation.representation(
            using: .png,
            properties: [:]
        ))
        return MenuBarQuickBarIconSnapshot(pngData: png, pointSize: pointSize)
    }
}
