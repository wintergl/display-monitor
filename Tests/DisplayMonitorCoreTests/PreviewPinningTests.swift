import DisplayMonitorCore
import XCTest

@testable import DisplayMonitor

final class PreviewPinningTests: XCTestCase {
    func testExistingSettingsKeepPinningEnabledWithoutLosingOtherPreferences() throws {
        let payload = Data("""
        {"schemaVersion":10,"frameRate":30,"previewWindowSize":"960x540"}
        """.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: payload).normalized

        XCTAssertTrue(settings.previewIsPinned)
        XCTAssertEqual(settings.frameRate, 30)
        XCTAssertEqual(settings.previewWindowSize, .extraLarge)
    }

    func testUnpinnedChoiceSurvivesSettingsEncodingAndNormalization() throws {
        let settings = AppSettings(previewIsPinned: false)
        let data = try JSONEncoder().encode(settings)
        let restored = try JSONDecoder().decode(AppSettings.self, from: data).normalized

        XCTAssertFalse(restored.previewIsPinned)
        XCTAssertEqual(restored, settings.normalized)
    }

    @MainActor
    func testChangingPinningPersistsWithoutStartingMonitorOrShowingPreview() throws {
        let suite = "DisplayMonitor.PreviewPinningTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        let model = AppModel(dependencies: .standard(settingsStore: store))

        model.setPreviewPinned(false)
        XCTAssertFalse(model.previewIsPinned)
        XCTAssertFalse(store.load().previewIsPinned)
        XCTAssertEqual(model.desiredMonitorState, .off)
        XCTAssertEqual(model.previewVisibility, .hidden)
        XCTAssertEqual(model.capturePhase, .idle)

        let restored = AppModel(dependencies: .standard(settingsStore: store))
        XCTAssertFalse(restored.previewIsPinned)
        restored.setPreviewPinned(true)
        XCTAssertTrue(restored.previewIsPinned)
        XCTAssertTrue(store.load().previewIsPinned)
    }
}
