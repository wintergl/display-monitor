import CoreGraphics
import XCTest
@testable import DisplayMonitorCore

final class DisplayMonitorCoreTests: XCTestCase {
    func testDirectControlModifierDefaultsToOptionAndExposesSettingsChoices() {
        XCTAssertEqual(AppSettings.safeDefault.directControlModifier, .option)
        XCTAssertEqual(DirectControlModifier.allCases, [.option, .control, .shift, .command])
        XCTAssertEqual(DirectControlModifier.option.symbol, "⌥")
        XCTAssertEqual(DirectControlModifier.option.label, "Option（Alt）")
        XCTAssertEqual(DirectControlModifier.command.symbol, "⌘")
    }

    func testDirectPointerCapturePolicyClampsPointerInsideTargetDisplay() {
        let bounds = CGRect(x: 1920, y: -200, width: 1280, height: 1024)

        XCTAssertEqual(
            DirectPointerCapturePolicy.clampedPoint(
                CGPoint(x: 5000, y: -900),
                to: bounds
            ),
            CGPoint(x: 3199, y: -199)
        )
        XCTAssertEqual(
            DirectPointerCapturePolicy.clampedPoint(
                CGPoint(x: 2400, y: 300),
                to: bounds
            ),
            CGPoint(x: 2400, y: 300)
        )
    }

    func testDirectPointerCapturePolicyDefersReturnUntilMouseButtonsAreReleased() {
        XCTAssertFalse(
            DirectPointerCapturePolicy.shouldDeferExit(pressedMouseButtonCount: 0)
        )
        XCTAssertTrue(
            DirectPointerCapturePolicy.shouldDeferExit(pressedMouseButtonCount: 1)
        )
    }

    func testDirectControlAutoEnablesOnlyForReadyVisiblePreview() {
        XCTAssertTrue(
            DirectControlActivationPolicy.shouldAutoEnable(
                previewVisibility: .shown,
                hasAccessibilityPermission: true,
                hasOnlineTarget: true,
                userDisabledForCurrentPreviewSession: false
            )
        )

        for visibility in [PreviewVisibility.collapsed, .hidden] {
            XCTAssertFalse(
                DirectControlActivationPolicy.shouldAutoEnable(
                    previewVisibility: visibility,
                    hasAccessibilityPermission: true,
                    hasOnlineTarget: true,
                    userDisabledForCurrentPreviewSession: false
                )
            )
        }

        XCTAssertFalse(
            DirectControlActivationPolicy.shouldAutoEnable(
                previewVisibility: .shown,
                hasAccessibilityPermission: false,
                hasOnlineTarget: true,
                userDisabledForCurrentPreviewSession: false
            )
        )
        XCTAssertFalse(
            DirectControlActivationPolicy.shouldAutoEnable(
                previewVisibility: .shown,
                hasAccessibilityPermission: true,
                hasOnlineTarget: false,
                userDisabledForCurrentPreviewSession: false
            )
        )
        XCTAssertFalse(
            DirectControlActivationPolicy.shouldAutoEnable(
                previewVisibility: .shown,
                hasAccessibilityPermission: true,
                hasOnlineTarget: true,
                userDisabledForCurrentPreviewSession: true
            )
        )
    }

    func testOutputSizeKeepsAspectRatioAndBounds() throws {
        let size = try OutputSizeCalculator.calculate(sourcePixelWidth: 3840, sourcePixelHeight: 2160)
        XCTAssertEqual(size, PixelSize(width: 960, height: 540))
    }

    func testOutputSizeSupportsUltrawide() throws {
        let size = try OutputSizeCalculator.calculate(sourcePixelWidth: 3440, sourcePixelHeight: 1440)
        XCTAssertEqual(size.width, 960)
        XCTAssertEqual(size.height, 400)
    }

    func testOutputSizeSupportsPortrait() throws {
        let size = try OutputSizeCalculator.calculate(sourcePixelWidth: 1080, sourcePixelHeight: 1920)
        XCTAssertEqual(size.width, 302)
        XCTAssertEqual(size.height, 540)
    }

    func testPreviewCoordinateMapperMapsCenterAndSupportsNegativeDisplayOrigin() {
        let mapped = PreviewCoordinateMapper.map(
            localPoint: CGPoint(x: 320, y: 180),
            previewBounds: CGRect(x: 0, y: 0, width: 640, height: 360),
            targetBounds: CGRect(x: -1920, y: 80, width: 1920, height: 1080),
            contentSize: CGSize(width: 1920, height: 1080)
        )

        guard let mapped else {
            XCTFail("expected a point inside the fitted content")
            return
        }
        XCTAssertEqual(mapped.x, -960, accuracy: 0.001)
        XCTAssertEqual(mapped.y, 620, accuracy: 0.001)
    }

    func testPreviewCoordinateMapperFlipsAppKitYIntoQuartzCoordinates() {
        let mapped = PreviewCoordinateMapper.map(
            localPoint: CGPoint(x: 160, y: 90),
            previewBounds: CGRect(x: 0, y: 0, width: 640, height: 360),
            targetBounds: CGRect(x: 1800, y: 0, width: 1920, height: 1080),
            contentSize: CGSize(width: 1920, height: 1080)
        )

        guard let mapped else {
            XCTFail("expected a point inside the fitted content")
            return
        }
        XCTAssertEqual(mapped.x, 2280, accuracy: 0.001)
        XCTAssertEqual(mapped.y, 810, accuracy: 0.001)
    }

    func testPreviewCoordinateMapperKeepsBottomEdgeInsideQuartzDisplay() {
        let targetBounds = CGRect(x: 1800, y: 0, width: 1920, height: 1080)
        let mapped = PreviewCoordinateMapper.map(
            localPoint: CGPoint(x: 320, y: 0),
            previewBounds: CGRect(x: 0, y: 0, width: 640, height: 360),
            targetBounds: targetBounds,
            contentSize: targetBounds.size
        )

        guard let mapped else {
            XCTFail("expected the bottom edge to map inside the display")
            return
        }
        XCTAssertLessThan(mapped.y, targetBounds.maxY)
        XCTAssertGreaterThan(mapped.y, targetBounds.maxY - 0.001)
    }

    func testPreviewCoordinateMapperRejectsAspectFitLetterbox() {
        let mapped = PreviewCoordinateMapper.map(
            localPoint: CGPoint(x: 10, y: 180),
            previewBounds: CGRect(x: 0, y: 0, width: 640, height: 360),
            targetBounds: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            contentSize: CGSize(width: 4, height: 3)
        )

        XCTAssertNil(mapped)
    }

    func testIdentityMatcherDoesNotGuessAmongDuplicateDisplays() {
        let identity = makeIdentity(serial: nil)
        let first = makeDescriptor(id: 11, identity: identity)
        let second = makeDescriptor(id: 12, identity: identity)

        let result = DisplayIdentityMatcher.match(
            lastSessionDisplayID: nil,
            identity: identity,
            candidates: [first, second]
        )

        XCTAssertEqual(result, .ambiguous)
    }

    func testIdentityMatcherPrefersValidSessionIDWhenDeviceMatches() {
        let identity = makeIdentity(serial: 42)
        let first = makeDescriptor(id: 11, identity: makeIdentity(serial: 99))
        let second = makeDescriptor(id: 12, identity: identity)

        let result = DisplayIdentityMatcher.match(
            lastSessionDisplayID: 12,
            identity: identity,
            candidates: [first, second]
        )

        XCTAssertEqual(result, .matched(second))
    }

    func testPermissionResolverDistinguishesRevokedFromFirstRun() {
        XCTAssertEqual(
            PermissionStateResolver.resolve(preflightGranted: false, previouslyObservedGrant: false),
            .notGranted
        )
        XCTAssertEqual(
            PermissionStateResolver.resolve(preflightGranted: false, previouslyObservedGrant: true),
            .revoked
        )
        XCTAssertEqual(
            PermissionStateResolver.resolve(preflightGranted: true, previouslyObservedGrant: false),
            .granted
        )
    }

    func testDisplayAvailabilityClassifierMarksInactiveAsNotShareable() {
        XCTAssertEqual(
            DisplayAvailabilityClassifier.classify(
                isOnline: true,
                isActive: false,
                isMirrored: false,
                isShareable: true
            ),
            .notShareable
        )
    }

    func testDisplayAvailabilityClassifierMirroredTakesPrecedence() {
        XCTAssertEqual(
            DisplayAvailabilityClassifier.classify(
                isOnline: true,
                isActive: true,
                isMirrored: true,
                isShareable: true
            ),
            .mirrored
        )
    }

    func testDisplayAvailabilityClassifierMarksUnmappedDisplayNotShareable() {
        XCTAssertEqual(
            DisplayAvailabilityClassifier.classify(
                isOnline: true,
                isActive: true,
                isMirrored: false,
                isShareable: false
            ),
            .notShareable
        )
    }

    func testDisplayAvailabilityClassifierCanaryStates() {
        XCTAssertEqual(
            DisplayAvailabilityClassifier.classify(
                isOnline: true,
                isActive: true,
                isMirrored: false,
                isShareable: true
            ),
            .candidate
        )
        XCTAssertEqual(
            DisplayAvailabilityClassifier.classify(
                isOnline: true,
                isActive: true,
                isMirrored: false,
                isShareable: true,
                canary: .succeeded
            ),
            .available
        )

        let error = CaptureError(code: "canary_timeout", message: "timeout")
        XCTAssertEqual(
            DisplayAvailabilityClassifier.classify(
                isOnline: true,
                isActive: true,
                isMirrored: false,
                isShareable: true,
                canary: .failed(error)
            ),
            .captureFailed(error)
        )
    }

    func testSettingsNormalizeInvalidFrameRate() {
        var settings = AppSettings.safeDefault
        settings.frameRate = 120
        XCTAssertEqual(settings.normalized.frameRate, 15)
        XCTAssertEqual(settings.normalized.schemaVersion, AppSettings.currentSchemaVersion)
    }

    func testSchema10DefaultsAddScreenshotWorkflowPreferences() throws {
        let settings = AppSettings.safeDefault
        XCTAssertEqual(AppSettings.currentSchemaVersion, 10)
        XCTAssertEqual(settings.preferredPreviewPresentation, .shown)
        XCTAssertEqual(settings.shelfMode, "safeVisibility(shelfNoGo)")
        XCTAssertEqual(settings.shortcutBindings["toggleMonitor"], "⌥F1")
        XCTAssertEqual(settings.scrollCaptureMode, .automaticFirstManualFallback)
        XCTAssertTrue(settings.artifactShelfAutoPresent)
        XCTAssertTrue(settings.artifactShelfFollowsActiveDisplay)
        XCTAssertEqual(settings.artifactShelfRecentLimit, 20)
        XCTAssertEqual(settings.artifactShelfMargin, 16)
        XCTAssertTrue(settings.artifactShelfRestoreOnLaunch)
        XCTAssertNil(settings.screenshotSaveDirectoryPath)
        XCTAssertEqual(settings.screenshotTimerDelaySeconds, 5)
        XCTAssertNil(settings.lastScreenshotDisplayID)
        XCTAssertNil(settings.lastScreenshotRegion)
        XCTAssertEqual(settings.lastScreenshotAnnotationTool, .arrow)

        let encoded = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: encoded).normalized
        XCTAssertEqual(decoded.preferredPreviewPresentation, .shown)
        XCTAssertEqual(decoded.schemaVersion, 10)
        XCTAssertNil(decoded.screenshotSaveDirectoryPath)
        XCTAssertEqual(decoded.screenshotTimerDelaySeconds, 5)
        XCTAssertEqual(decoded.lastScreenshotAnnotationTool, .arrow)
    }

    func testSchema10MigratesLegacyPreviewPresentationWithoutStartingRuntime() throws {
        let legacyPayload = Data("""
        {
          "schemaVersion": 5,
          "previewIsVisible": true,
          "previewIsCollapsed": true
        }
        """.utf8)

        let settings = try JSONDecoder().decode(AppSettings.self, from: legacyPayload).normalized
        XCTAssertEqual(settings.preferredPreviewPresentation, .collapsed)
        XCTAssertEqual(settings.schemaVersion, 10)
        XCTAssertEqual(settings.shelfMode, "safeVisibility(shelfNoGo)")
        XCTAssertEqual(settings.shortcutBindings["captureRegion"], "⌥A")
        XCTAssertTrue(settings.artifactShelfFollowsActiveDisplay)
        XCTAssertNil(settings.screenshotSaveDirectoryPath)
        XCTAssertEqual(settings.screenshotTimerDelaySeconds, 5)
        XCTAssertEqual(settings.lastScreenshotAnnotationTool, .arrow)
    }

    func testScreenshotWorkflowPreferencesRoundTripAndNormalizeTimer() throws {
        let region = try ScreenCoordinateAdapter.makeRegion(
            displayFrame: CGRect(x: -1440, y: 0, width: 1440, height: 900),
            selectionRect: CGRect(x: -1200, y: 140, width: 640, height: 360),
            pixelScale: 2
        )
        var settings = AppSettings.safeDefault
        settings.screenshotTimerDelaySeconds = 10
        settings.lastScreenshotDisplayID = 42
        settings.lastScreenshotRegion = region
        settings.lastScreenshotAnnotationTool = .spotlight

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data).normalized

        XCTAssertEqual(decoded.screenshotTimerDelaySeconds, 10)
        XCTAssertEqual(decoded.lastScreenshotDisplayID, 42)
        XCTAssertEqual(decoded.lastScreenshotRegion, region)
        XCTAssertEqual(decoded.lastScreenshotAnnotationTool, .spotlight)

        settings.screenshotTimerDelaySeconds = 99
        XCTAssertEqual(settings.normalized.screenshotTimerDelaySeconds, 5)
    }

    func testScreenshotOutputLocationUsesFixedNameAndAddsSuffixWithoutOverwrite() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DisplayMonitorOutputLocation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try ScreenshotOutputLocation.nextAvailableURL(
            in: directory,
            baseName: "Display Monitor Screenshot",
            pathExtension: "png"
        )
        XCTAssertEqual(first.lastPathComponent, "Display Monitor Screenshot.png")
        try Data("first".utf8).write(to: first)

        let second = try ScreenshotOutputLocation.nextAvailableURL(
            in: directory,
            baseName: "Display Monitor Screenshot",
            pathExtension: ".png"
        )
        XCTAssertEqual(second.lastPathComponent, "Display Monitor Screenshot 2.png")
    }

    func testScreenshotOutputLocationRejectsRelativeOrBlankConfiguredPaths() {
        let defaultDirectory = ScreenshotOutputLocation.defaultDirectory()
        XCTAssertEqual(
            ScreenshotOutputLocation.resolvedDirectory(path: " relative/path "),
            defaultDirectory
        )
        XCTAssertEqual(
            ScreenshotOutputLocation.resolvedDirectory(path: "   "),
            defaultDirectory
        )
        XCTAssertEqual(
            ScreenshotOutputLocation.resolvedDirectory(path: "/tmp/display-monitor-output"),
            URL(fileURLWithPath: "/tmp/display-monitor-output", isDirectory: true).standardizedFileURL
        )
    }

    func testSettingsPersistConfiguredScreenshotSaveDirectory() throws {
        var settings = AppSettings.safeDefault
        settings.screenshotSaveDirectoryPath = "/tmp/display-monitor-screenshots"

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data).normalized

        XCTAssertEqual(decoded.screenshotSaveDirectoryPath, "/tmp/display-monitor-screenshots")
        XCTAssertEqual(decoded.schemaVersion, AppSettings.currentSchemaVersion)
    }

    func testSettingsPersistDisabledArtifactShelfFollowPreference() throws {
        var settings = AppSettings.safeDefault
        settings.artifactShelfFollowsActiveDisplay = false

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data).normalized

        XCTAssertFalse(decoded.artifactShelfFollowsActiveDisplay)
        XCTAssertEqual(decoded.schemaVersion, AppSettings.currentSchemaVersion)
    }

    func testSafeVisibilityStateRemainsExplicitlyNoGo() {
        let state = ShelfState.safeVisibility(.shelfNoGo)
        XCTAssertTrue(state.isSafeVisibility)
        XCTAssertEqual(state.label, "Safe Visibility（Shelf No-Go）")
        XCTAssertTrue(ShelfSafeVisibilityPolicy().preservesRecoveryActions)
        XCTAssertFalse(ShelfSafeVisibilityPolicy().allowsThirdPartyMoves)
    }

    func testCaptureResolutionPresetsExposeExpectedSizes() {
        XCTAssertEqual(CaptureResolutionPreset.compact.maxPixelSize, PixelSize(width: 320, height: 180))
        XCTAssertEqual(CaptureResolutionPreset.small.maxPixelSize, PixelSize(width: 480, height: 270))
        XCTAssertEqual(CaptureResolutionPreset.medium.maxPixelSize, PixelSize(width: 640, height: 360))
        XCTAssertEqual(CaptureResolutionPreset.large.maxPixelSize, PixelSize(width: 960, height: 540))
        XCTAssertEqual(CaptureResolutionPreset.hd.maxPixelSize, PixelSize(width: 1280, height: 720))
        XCTAssertEqual(CaptureResolutionPreset.fullHD.maxPixelSize, PixelSize(width: 1920, height: 1080))
        XCTAssertEqual(CaptureResolutionPreset.qhd.maxPixelSize, PixelSize(width: 2560, height: 1440))
        XCTAssertEqual(CaptureResolutionPreset.selectableCases, [.hd, .fullHD, .qhd])
    }

    func testPreviewWindowSizePresetsAreIndependentFromCaptureResolution() {
        XCTAssertEqual(PreviewWindowSizePreset.compact.contentSize, CGSize(width: 240, height: 135))
        XCTAssertEqual(PreviewWindowSizePreset.small.contentSize, CGSize(width: 320, height: 180))
        XCTAssertEqual(PreviewWindowSizePreset.medium.contentSize, CGSize(width: 480, height: 270))
        XCTAssertEqual(PreviewWindowSizePreset.large.contentSize, CGSize(width: 640, height: 360))
        XCTAssertEqual(PreviewWindowSizePreset.extraLarge.contentSize, CGSize(width: 960, height: 540))
        XCTAssertEqual(PreviewWindowSizePreset.hd.contentSize, CGSize(width: 1280, height: 720))
        XCTAssertEqual(PreviewWindowSizePreset.selectableCases, [.large, .extraLarge, .hd])
        XCTAssertNotEqual(
            CGSize(
                width: CaptureResolutionPreset.hd.maxPixelSize.width,
                height: CaptureResolutionPreset.hd.maxPixelSize.height
            ),
            PreviewWindowSizePreset.large.contentSize
        )
    }

    func testSettingsNormalizeLowResolutionAndSmallPreviewToSupportedMinimums() {
        var settings = AppSettings.safeDefault
        settings.captureResolution = .compact
        settings.previewWindowSize = .small
        settings.previewContentFrame = CGRect(x: 10, y: 10, width: 320, height: 180)

        let normalized = settings.normalized

        XCTAssertEqual(normalized.captureResolution, .hd)
        XCTAssertEqual(normalized.previewWindowSize, .large)
        XCTAssertNil(normalized.previewContentFrame)
    }

    func testSettingsNormalizeHiddenPreviewClearsCollapsedFlag() {
        var settings = AppSettings.safeDefault
        settings.previewIsVisible = false
        settings.previewIsCollapsed = true

        let normalized = settings.normalized

        XCTAssertFalse(normalized.previewIsVisible)
        XCTAssertFalse(normalized.previewIsCollapsed)
    }

    func testSettingsDecodeLegacyPayloadWithoutSchemaVersion() throws {
        let legacyPayload = Data("""
        {
          "frameRate": 10,
          "showsCursor": false,
          "previewIsVisible": false,
          "captureIsPaused": true,
          "permissionGrantPreviouslyObserved": true
        }
        """.utf8)

        let settings = try JSONDecoder().decode(AppSettings.self, from: legacyPayload).normalized

        XCTAssertEqual(settings.schemaVersion, AppSettings.currentSchemaVersion)
        XCTAssertEqual(settings.frameRate, 10)
        XCTAssertEqual(settings.captureResolution, .hd)
        XCTAssertEqual(settings.previewWindowSize, .large)
        XCTAssertEqual(settings.directControlModifier, .option)
        XCTAssertFalse(settings.showsCursor)
        XCTAssertFalse(settings.previewIsVisible)
        XCTAssertFalse(settings.previewIsCollapsed)
        XCTAssertTrue(settings.captureIsPaused)
        XCTAssertTrue(settings.permissionGrantPreviouslyObserved)
        XCTAssertNil(settings.selectedDisplay)
        XCTAssertNil(settings.lastSessionDisplayID)
    }

    func testSettingsMigrateSchema2LargeCaptureToHighCaptureAndMinimumWindow() throws {
        let legacyPayload = Data("""
        {
          "schemaVersion": 2,
          "frameRate": 15,
          "captureResolution": "960x540",
          "previewContentFrame": [[600, 0], [960, 540]],
          "previewIsVisible": true
        }
        """.utf8)

        let settings = try JSONDecoder().decode(AppSettings.self, from: legacyPayload).normalized

        XCTAssertEqual(settings.schemaVersion, AppSettings.currentSchemaVersion)
        XCTAssertEqual(settings.captureResolution, .hd)
        XCTAssertEqual(settings.previewWindowSize, .large)
        XCTAssertNil(settings.previewContentFrame)
    }

    func testSettingsPersistConfiguredDirectControlModifier() throws {
        var settings = AppSettings.safeDefault
        settings.directControlModifier = .control

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data).normalized

        XCTAssertEqual(decoded.schemaVersion, AppSettings.currentSchemaVersion)
        XCTAssertEqual(decoded.directControlModifier, .control)
    }

    func testPhase0ShelfFixtureCatalogIsVersionedAndComplete() {
        XCTAssertEqual(ShelfSpikeFixtureCatalog.version, "shelf-spike-fixture-v1")
        XCTAssertEqual(ShelfSpikeFixtureCatalog.fixtures.map(\.id), [
            "F-1", "F-2", "F-3", "F-4", "F-5", "F-6", "F-7"
        ])
        XCTAssertEqual(
            Set(ShelfSpikeFixtureCatalog.fixtures.map(\.expectedClassification)),
            Set(ShelfItemClassification.allCases)
        )
    }

    func testPhase0ShelfClassifierNeverMovesProtectedOrUnsupportedItems() {
        XCTAssertEqual(
            ShelfClassifier.classify(
                isSystemItem: true,
                isToolSuiteItem: false,
                axAvailable: true,
                identityStable: true,
                canReadPosition: true,
                canWritePosition: true
            ),
            .protected
        )
        XCTAssertEqual(
            ShelfClassifier.classify(
                isSystemItem: false,
                isToolSuiteItem: false,
                axAvailable: false,
                identityStable: true,
                canReadPosition: true,
                canWritePosition: true,
                failure: .apiDisabled
            ),
            .unsupported
        )
        XCTAssertEqual(
            ShelfClassifier.classify(
                isSystemItem: false,
                isToolSuiteItem: false,
                axAvailable: true,
                identityStable: true,
                canReadPosition: true,
                canWritePosition: false
            ),
            .protected
        )
    }

    func testPhase0ShelfJournalRequiresSafeStartupAndPreservesInverse() {
        let identity = MenuItemIdentity(bundleID: "fixture", titleFingerprint: "fixture-a")
        let anchor = MenuItemIdentity(bundleID: "com.hanshuai.DisplayMonitor", titleFingerprint: "anchor")
        let snapshot = MenuBarLayoutSnapshot(anchorIdentity: anchor)
        var journal = ShelfTransactionJournal(
            beforeSnapshot: snapshot,
            operations: [ShelfMoveOperation(itemIdentity: identity, from: .visible, to: .hidden)],
            status: .applying
        )

        XCTAssertTrue(journal.hasInverseForEveryOperation)
        XCTAssertTrue(journal.requiresSafeStartup)
        XCTAssertEqual(
            ShelfRecoveryPolicy.decision(journal: journal, accessibilityAvailable: true),
            .safeStartup(reason: "发现未完成 Shelf 事务，启动只读恢复")
        )
        XCTAssertEqual(
            ShelfRecoveryPolicy.decision(journal: journal, accessibilityAvailable: false),
            .repairNeeded(reason: "Accessibility 不可用，禁止继续拖动")
        )

        journal.operations[0].inverseTo = .alwaysHidden
        XCTAssertFalse(journal.hasInverseForEveryOperation)
        XCTAssertEqual(
            ShelfRecoveryPolicy.decision(journal: journal, accessibilityAvailable: true),
            .repairNeeded(reason: "journal 缺少完整逆操作")
        )
    }

    func testPhase0SafeVisibilityPolicyDisablesThirdPartyMutation() {
        let policy = ShelfSafeVisibilityPolicy()

        XCTAssertFalse(policy.allowsThirdPartyMoves)
        XCTAssertTrue(policy.exposesReadOnlyInventory)
        XCTAssertTrue(policy.preservesRecoveryActions)
    }

    func testPhase0OptionAConsumesBothKeyEventsAndRoutesOneCommand() {
        var arbiter = Phase0InputArbiter()
        var effects: [Phase0InputEffect] = []
        for event in [
            Phase0InputEvent.modifierDown(.option),
            .keyDown(.a),
            .keyUp(.a),
            .modifierUp(.option)
        ] {
            effects += arbiter.process(event).effects
        }

        let trace = Phase0InputTrace(effects: effects)
        XCTAssertEqual(trace.commands, [.captureRegion])
        XCTAssertEqual(trace.leakedShortcutKeyEvents, 0)
        XCTAssertTrue(effects.contains(.consumedKeyDown(.a)))
        XCTAssertTrue(effects.contains(.consumedKeyUp(.a)))
    }

    func testPhase0OptionF1ConsumesBothKeyEventsAndRoutesOneCommand() {
        var arbiter = Phase0InputArbiter()
        var effects: [Phase0InputEffect] = []
        for event in [
            Phase0InputEvent.modifierDown(.option),
            .keyDown(.f1),
            .keyUp(.f1),
            .modifierUp(.option)
        ] {
            effects += arbiter.process(event).effects
        }

        let trace = Phase0InputTrace(effects: effects)
        XCTAssertEqual(trace.commands, [.toggleMonitor])
        XCTAssertEqual(trace.leakedShortcutKeyEvents, 0)
        XCTAssertTrue(effects.contains(.consumedKeyDown(.f1)))
        XCTAssertTrue(effects.contains(.consumedKeyUp(.f1)))
    }

    func testPhase0UnregisteredOptionKeyIsForwardedOnceAndDoesNotArmDirectPointer() {
        var arbiter = Phase0InputArbiter()
        var effects: [Phase0InputEffect] = []
        for event in [
            Phase0InputEvent.modifierDown(.option),
            .keyDown(.unregistered),
            .keyUp(.unregistered),
            .pointerMotion(insidePreviewContent: true),
            .modifierUp(.option)
        ] {
            effects += arbiter.process(event).effects
        }

        XCTAssertEqual(Phase0InputTrace(effects: effects).commands, [])
        XCTAssertEqual(
            effects.filter {
                if case .forwardedKey(.unregistered, _) = $0 { return true }
                return false
            }.count,
            2
        )
        XCTAssertFalse(effects.contains(.directPointerStarted))
    }

    func testPhase0OptionOnlyPointerClickAndScrollStripModifierOnlyInsidePreview() {
        var arbiter = Phase0InputArbiter()
        var effects: [Phase0InputEffect] = []
        for event in [
            Phase0InputEvent.modifierDown(.option),
            .pointerMotion(insidePreviewContent: true),
            .pointer(.click, insidePreviewContent: true),
            .pointer(.scroll, insidePreviewContent: true),
            .modifierUp(.option)
        ] {
            effects += arbiter.process(event).effects
        }

        XCTAssertTrue(effects.contains(.directPointerStarted))
        XCTAssertTrue(effects.contains(.directPointerStopped))
        XCTAssertTrue(effects.contains(.forwardedPointer(.click, strippedModifier: true)))
        XCTAssertTrue(effects.contains(.forwardedPointer(.scroll, strippedModifier: true)))
    }

    func testPhase0DirectPointerChordWaitsForMouseUpBeforeStoppingAndDispatching() {
        var arbiter = Phase0InputArbiter()
        var effects: [Phase0InputEffect] = []
        for event in [
            Phase0InputEvent.modifierDown(.option),
            .pointerMotion(insidePreviewContent: true),
            .pointer(.mouseDown, insidePreviewContent: true),
            .keyDown(.a),
            .keyUp(.a),
            .modifierUp(.option)
        ] {
            effects += arbiter.process(event).effects
        }

        XCTAssertTrue(effects.contains(.directPointerStopDeferred))
        XCTAssertFalse(effects.contains(.directPointerStopped))
        XCTAssertEqual(Phase0InputTrace(effects: effects).commands, [])

        effects += arbiter.process(.pointer(.mouseUp, insidePreviewContent: true)).effects
        let trace = Phase0InputTrace(effects: effects)
        XCTAssertTrue(effects.contains(.directPointerStopped))
        XCTAssertEqual(trace.commands, [.captureRegion])
        XCTAssertFalse(trace.hasStuckButton)
    }

    func testPhase0SelectionLeaseBlocksOptionDirectPointer() {
        var arbiter = Phase0InputArbiter()
        var effects: [Phase0InputEffect] = []
        for event in [
            Phase0InputEvent.selectionMode(active: true),
            .modifierDown(.option),
            .pointerMotion(insidePreviewContent: true),
            .modifierUp(.option),
            .selectionMode(active: false)
        ] {
            effects += arbiter.process(event).effects
        }

        XCTAssertTrue(effects.contains(.selectionBlocked))
        XCTAssertFalse(effects.contains(.directPointerStarted))
    }

    func testPhase0InputArbitrationRepeatsRequiredSequences100TimesWithoutLeak() {
        var totalEffects: [Phase0InputEffect] = []
        for _ in 0..<Phase0SpikeContract.minimumInputIterations {
            var arbiter = Phase0InputArbiter()
            for event in [
                Phase0InputEvent.modifierDown(.option),
                .keyDown(.a),
                .keyUp(.a),
                .modifierUp(.option),
                .modifierDown(.option),
                .keyDown(.f1),
                .keyUp(.f1),
                .modifierUp(.option)
            ] {
                totalEffects += arbiter.process(event).effects
            }
        }

        let trace = Phase0InputTrace(effects: totalEffects)
        XCTAssertEqual(trace.commands.count, Phase0SpikeContract.minimumInputIterations * 2)
        XCTAssertEqual(trace.leakedShortcutKeyEvents, 0)
    }

    func testPhase0RegistrationFailureDisablesDirectPointerForThatChord() {
        var arbiter = Phase0InputArbiter(captureRegistered: false)
        var effects: [Phase0InputEffect] = []
        for event in [
            Phase0InputEvent.modifierDown(.option),
            .keyDown(.a),
            .keyUp(.a),
            .pointerMotion(insidePreviewContent: true),
            .modifierUp(.option)
        ] {
            effects += arbiter.process(event).effects
        }

        XCTAssertEqual(Phase0InputTrace(effects: effects).commands, [])
        XCTAssertFalse(effects.contains(.directPointerStarted))
        XCTAssertEqual(
            effects.filter {
                if case .forwardedKey(.a, _) = $0 { return true }
                return false
            }.count,
            2
        )
    }

    func testPhase0CaptureRegionVectorsAndPipelineAgreement() throws {
        let vectors: [(CGRect, CGRect, Double, CGRect, CapturePixelRect)] = [
            (
                CGRect(x: 0, y: 0, width: 1920, height: 1080),
                CGRect(x: 100, y: 200, width: 400, height: 300),
                2,
                CGRect(x: 100, y: 580, width: 400, height: 300),
                CapturePixelRect(minX: 200, minY: 1160, width: 800, height: 600)
            ),
            (
                CGRect(x: -1920, y: 0, width: 1920, height: 1080),
                CGRect(x: -1800, y: 100, width: 640, height: 480),
                1,
                CGRect(x: 120, y: 500, width: 640, height: 480),
                CapturePixelRect(minX: 120, minY: 500, width: 640, height: 480)
            ),
            (
                CGRect(x: 0, y: 0, width: 1280, height: 720),
                CGRect(x: 10, y: 650, width: 100, height: 50),
                2,
                CGRect(x: 10, y: 20, width: 100, height: 50),
                CapturePixelRect(minX: 20, minY: 40, width: 200, height: 100)
            )
        ]

        for (display, selection, scale, expectedLocal, expectedPixels) in vectors {
            let screenshot = try ScreenCoordinateAdapter.makeRegion(
                displayFrame: display,
                selectionRect: selection,
                pixelScale: scale
            )
            let recording = try ScreenCoordinateAdapter.makeRegion(
                displayFrame: display,
                selectionRect: selection,
                pixelScale: scale
            )
            XCTAssertEqual(screenshot.selectionRectInDisplayLocalPoints, expectedLocal)
            XCTAssertEqual(screenshot.pixelRectInCaptureSpace, expectedPixels)
            XCTAssertTrue(ScreenCoordinateAdapter.pipelineRegionsAgree(screenshot: screenshot, recording: recording))
        }
    }

    func testPhase0CaptureRegionRotatesRectangleUsingFourCorners() throws {
        let region = try ScreenCoordinateAdapter.makeRegion(
            displayFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            selectionRect: CGRect(x: 100, y: 580, width: 400, height: 300),
            pixelScale: 1,
            orientation: .rotate90CW
        )

        XCTAssertEqual(region.sourceRectInPlatformLogicalPoints, CGRect(x: 580, y: 100, width: 300, height: 400))
        XCTAssertEqual(region.pixelRectInCaptureSpace, CapturePixelRect(minX: 580, minY: 100, width: 300, height: 400))
    }

    func testPhase0StatusItemLifecycleKeepsRolesIndependent() {
        var model = StatusItemLifecycleModel()
        model.create(.toolSuiteAnchor)
        model.create(.monitorActivity)
        XCTAssertTrue(model.hasIndependentLifecycle)

        model.setVisible(.monitorActivity, false)
        XCTAssertTrue(model.liveRoles.contains(.toolSuiteAnchor))
        XCTAssertTrue(model.visibleRoles.contains(.toolSuiteAnchor))
        XCTAssertFalse(model.visibleRoles.contains(.monitorActivity))

        model.setVisible(.monitorActivity, true)
        model.destroy(.monitorActivity)
        XCTAssertEqual(model.liveRoles, [.toolSuiteAnchor])
        XCTAssertEqual(model.visibleRoles, [.toolSuiteAnchor])
    }

    func testCaptureRetryPolicyBackoffAndLimits() {
        XCTAssertEqual(CaptureRetryPolicy.delaySeconds(forAttempt: 1), 0.5)
        XCTAssertEqual(CaptureRetryPolicy.delaySeconds(forAttempt: 2), 1.0)
        XCTAssertEqual(CaptureRetryPolicy.delaySeconds(forAttempt: 3), 2.0)
        XCTAssertNil(CaptureRetryPolicy.delaySeconds(forAttempt: 4))

        let transient = CaptureError(code: "stream_start_failed", message: "failed")
        XCTAssertTrue(CaptureRetryPolicy.shouldRetry(transient, attempt: 1))
        XCTAssertTrue(CaptureRetryPolicy.shouldRetry(transient, attempt: 2))
        XCTAssertFalse(CaptureRetryPolicy.shouldRetry(transient, attempt: 3))
    }

    func testCaptureRetryPolicyDoesNotRetryPermanentConfigurationErrors() {
        let permanentErrors = [
            "display_not_shareable",
            "current_app_not_unique",
            "source_size_mismatch",
            "invalid_source_size",
            "display_not_selectable"
        ]

        for code in permanentErrors {
            let error = CaptureError(code: code, message: "permanent")
            XCTAssertFalse(CaptureRetryPolicy.shouldRetry(error, attempt: 1), code)
        }
    }

    func testWindowFrameResolverKeepsVisibleSavedFrame() {
        let visibleFrame = CGRect(x: 0, y: 25, width: 1440, height: 875)
        let savedFrame = CGRect(x: 900, y: 100, width: 480, height: 270)

        let resolved = WindowFrameResolver.resolve(
            savedFrame: savedFrame,
            visibleFrames: [visibleFrame],
            mainVisibleFrame: visibleFrame
        )

        XCTAssertEqual(resolved, savedFrame)
    }

    func testWindowFrameResolverFallsBackWhenFrameIsOffscreen() {
        let visibleFrame = CGRect(x: 0, y: 25, width: 1440, height: 875)
        let savedFrame = CGRect(x: 2000, y: 100, width: 480, height: 270)

        let resolved = WindowFrameResolver.resolve(
            savedFrame: savedFrame,
            visibleFrames: [visibleFrame],
            mainVisibleFrame: visibleFrame
        )

        XCTAssertEqual(resolved, CGRect(x: 944, y: 41, width: 480, height: 270))
    }

    func testWindowFrameResolverFallsBackWhenIntersectionIsTooSmall() {
        let visibleFrame = CGRect(x: 0, y: 25, width: 1440, height: 875)
        let savedFrame = CGRect(x: 1360, y: 850, width: 480, height: 270)

        XCTAssertFalse(WindowFrameResolver.hasEnoughVisibleIntersection(savedFrame, visibleFrames: [visibleFrame]))

        let resolved = WindowFrameResolver.resolve(
            savedFrame: savedFrame,
            visibleFrames: [visibleFrame],
            mainVisibleFrame: visibleFrame
        )

        XCTAssertEqual(resolved, CGRect(x: 944, y: 41, width: 480, height: 270))
    }

    func testWindowFrameResolverShrinksDefaultFrameForSmallVisibleFrame() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 360, height: 240)

        let resolved = WindowFrameResolver.defaultFrame(in: visibleFrame)

        XCTAssertEqual(resolved, CGRect(x: 16, y: 16, width: 328, height: 208))
    }

    private func makeIdentity(serial: UInt32?) -> PersistentDisplayIdentity {
        PersistentDisplayIdentity(
            vendorID: 100,
            modelID: 200,
            serialNumber: serial,
            localizedName: "Panel",
            lastKnownPixelWidth: 1920,
            lastKnownPixelHeight: 1080,
            isBuiltin: false
        )
    }

    private func makeDescriptor(id: CGDirectDisplayID, identity: PersistentDisplayIdentity) -> DisplayDescriptor {
        DisplayDescriptor(
            id: id,
            localizedName: identity.localizedName,
            logicalSize: PixelSize(width: 1920, height: 1080),
            pixelSize: PixelSize(width: 1920, height: 1080),
            isPrimary: false,
            isOnline: true,
            isBuiltin: false,
            isMirrored: false,
            captureAvailability: .candidate,
            persistentIdentity: identity
        )
    }
}
