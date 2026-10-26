import DisplayMonitorCore
import XCTest

final class ArtifactDiskCapacityTests: XCTestCase {
    func testZeroImportantEstimateDoesNotHideConfirmedFreeSpace() {
        XCTAssertEqual(ArtifactDiskCapacity.availableBytes(importantUsage: 0, ordinary: 86_458_515_456), 86_458_515_456)
        XCTAssertEqual(ArtifactDiskCapacity.availableBytes(importantUsage: 300, ordinary: 100), 300)
        XCTAssertEqual(ArtifactDiskCapacity.availableBytes(importantUsage: nil, ordinary: 100), 100)
    }

    func testUnknownOrInvalidCapacityCannotInventFreeSpace() {
        XCTAssertEqual(ArtifactDiskCapacity.availableBytes(importantUsage: nil, ordinary: nil), 0)
        XCTAssertEqual(ArtifactDiskCapacity.availableBytes(importantUsage: -1, ordinary: 0), 0)
    }

    func testActualWritableTemporaryVolumePassesStorageProbe() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("capacity-probe-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try await ArtifactStore(rootURL: root).preflightWriteAvailability(minimumFreeBytes: 1)
    }
}
