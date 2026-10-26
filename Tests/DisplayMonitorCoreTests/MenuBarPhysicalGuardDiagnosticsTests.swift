import ApplicationServices
import XCTest
@testable import DisplayMonitor

final class MenuBarPhysicalGuardDiagnosticsTests: XCTestCase {
    func testEmptyDiagnosticsHaveStableNonSensitiveSummary() {
        let diagnostics = MenuBarPhysicalGuardDiagnostics()

        XCTAssertEqual(diagnostics.totalCount, 0)
        XCTAssertTrue(diagnostics.counts.isEmpty)
        XCTAssertEqual(diagnostics.summary, "none")
    }

    func testDiagnosticsAggregateReasonsAndSortSummaryByFixedKey() {
        var diagnostics = MenuBarPhysicalGuardDiagnostics()
        diagnostics.record(.unrecognizedLeafOther)
        diagnostics.record(.rootChildUnexpectedRole, count: 2)
        diagnostics.record(.roleBulkAbsent, count: 26)
        diagnostics.record(.roleRecoveredBySingleRead, count: 26)
        diagnostics.record(.roleFallbackFailed)
        diagnostics.record(.rootChildUnexpectedRole)
        diagnostics.record(.itemFrameUnavailable, count: 0)

        XCTAssertEqual(diagnostics.totalCount, 57)
        XCTAssertEqual(diagnostics.counts[.rootChildUnexpectedRole], 3)
        XCTAssertEqual(diagnostics.counts[.roleBulkAbsent], 26)
        XCTAssertEqual(diagnostics.counts[.roleRecoveredBySingleRead], 26)
        XCTAssertEqual(diagnostics.counts[.roleFallbackFailed], 1)
        XCTAssertEqual(diagnostics.counts[.unrecognizedLeafOther], 1)
        XCTAssertNil(diagnostics.counts[.itemFrameUnavailable])
        XCTAssertEqual(
            diagnostics.summary,
            "roleBulkAbsent=26,roleFallbackFailed=1,"
                + "roleRecoveredBySingleRead=26,"
                + "rootChildUnexpectedRole=3,unrecognizedLeafOther=1"
        )
    }

    func testKnownRootProxyRolesHaveStableDedicatedReasons() {
        XCTAssertEqual(
            AnchoredMenuBarDiscovery.unexpectedRootChildReason(for: kAXMenuBarRole),
            .rootChildMenuBarProxy
        )
        XCTAssertEqual(
            AnchoredMenuBarDiscovery.unexpectedRootChildReason(for: kAXMenuRole),
            .rootChildMenuProxy
        )
        XCTAssertEqual(
            AnchoredMenuBarDiscovery.unexpectedRootChildReason(for: kAXGroupRole),
            .rootChildGroupProxy
        )
        XCTAssertEqual(
            AnchoredMenuBarDiscovery.unexpectedRootChildReason(for: kAXButtonRole),
            .rootChildButtonProxy
        )
        XCTAssertEqual(
            AnchoredMenuBarDiscovery.unexpectedRootChildReason(for: "AXFutureProxy"),
            .rootChildUnexpectedRole
        )
    }

    func testDiscoveryResultDefaultsToNoPhysicalGuardDiagnostics() {
        let result = AnchoredMenuBarDiscoveryResult(
            inventory: AnchoredMenuBarInventory(
                items: [],
                coverage: MenuBarInventoryCoverage(
                    expectedDisplayIDs: [],
                    observedCandidateCount: 0,
                    resolvedItemCount: 0
                ),
                anchorIdentity: MenuBarAnchorIdentity(
                    bundleIdentifier: "com.example.anchor",
                    title: "Anchor"
                )
            ),
            physicalItems: [],
            messages: []
        )

        XCTAssertEqual(result.physicalGuardDiagnostics, MenuBarPhysicalGuardDiagnostics())
    }
}
