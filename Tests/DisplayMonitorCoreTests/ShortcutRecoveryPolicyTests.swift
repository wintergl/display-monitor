import Carbon.HIToolbox
import CoreGraphics
@testable import DisplayMonitor
import XCTest

final class ShortcutRecoveryPolicyTests: XCTestCase {
    func testGlobalShortcutRegistrationUsesExclusiveOwnership() {
        XCTAssertEqual(
            GlobalShortcutRegistrationPolicy.options,
            UInt32(kEventHotKeyExclusive)
        )
    }

    func testEventFallbackMatchesConfiguredOptionAExactly() throws {
        let binding = try XCTUnwrap(
            ShortcutRegistry.defaultBindings.first { $0.command == .captureRegion }
        )

        XCTAssertTrue(GlobalShortcutEventMatcher.matches(
            keyCode: UInt16(kVK_ANSI_A),
            flags: .maskAlternate,
            binding: binding
        ))
        XCTAssertFalse(GlobalShortcutEventMatcher.matches(
            keyCode: UInt16(kVK_ANSI_A),
            flags: [.maskAlternate, .maskShift],
            binding: binding
        ))
        XCTAssertFalse(GlobalShortcutEventMatcher.matches(
            keyCode: UInt16(kVK_ANSI_S),
            flags: .maskAlternate,
            binding: binding
        ))
    }

    func testEventFallbackIgnoresNonShortcutEventFlags() throws {
        let binding = try XCTUnwrap(
            ShortcutRegistry.defaultBindings.first { $0.command == .captureRegion }
        )

        XCTAssertTrue(GlobalShortcutEventMatcher.matches(
            keyCode: UInt16(kVK_ANSI_A),
            flags: [.maskAlternate, .maskNonCoalesced],
            binding: binding
        ))
    }

    @MainActor
    func testMissingOptionRegistrationsAreNotReportedAsSafe() {
        let router = ShortcutRouter()

        XCTAssertFalse(router.hasSafeOptionChordRegistration)
    }

    func testSecureInputReleaseRequestsRegistration() {
        var policy = ShortcutRecoveryPolicy()

        XCTAssertFalse(policy.shouldRegister(
            secureInputEnabled: true,
            symbolicHotKeyMode: UInt32(kHIHotKeyModeAllEnabled),
            registrationsHealthy: true,
            recoveryAllowed: true
        ))
        XCTAssertTrue(policy.shouldRegister(
            secureInputEnabled: false,
            symbolicHotKeyMode: UInt32(kHIHotKeyModeAllEnabled),
            registrationsHealthy: true,
            recoveryAllowed: true
        ))
    }

    func testLifecycleRecoveryWaitsUntilSecureInputEnds() {
        var policy = ShortcutRecoveryPolicy()
        policy.requestLifecycleRecovery()

        XCTAssertFalse(policy.shouldRegister(
            secureInputEnabled: true,
            symbolicHotKeyMode: UInt32(kHIHotKeyModeAllEnabled),
            registrationsHealthy: true,
            recoveryAllowed: true
        ))
        XCTAssertTrue(policy.shouldRegister(
            secureInputEnabled: false,
            symbolicHotKeyMode: UInt32(kHIHotKeyModeAllEnabled),
            registrationsHealthy: true,
            recoveryAllowed: true
        ))
        XCTAssertFalse(policy.shouldRegister(
            secureInputEnabled: false,
            symbolicHotKeyMode: UInt32(kHIHotKeyModeAllEnabled),
            registrationsHealthy: true,
            recoveryAllowed: true
        ))
    }

    func testUnhealthyRegistrationRetriesWhenRecoveryIsAllowed() {
        var policy = ShortcutRecoveryPolicy()

        XCTAssertTrue(policy.shouldRegister(
            secureInputEnabled: false,
            symbolicHotKeyMode: UInt32(kHIHotKeyModeAllEnabled),
            registrationsHealthy: false,
            recoveryAllowed: true
        ))
        XCTAssertFalse(policy.shouldRegister(
            secureInputEnabled: false,
            symbolicHotKeyMode: UInt32(kHIHotKeyModeAllEnabled),
            registrationsHealthy: false,
            recoveryAllowed: false
        ))
    }

    func testSymbolicHotKeyModeReleaseRequestsRegistration() {
        var policy = ShortcutRecoveryPolicy()

        XCTAssertFalse(policy.shouldRegister(
            secureInputEnabled: false,
            symbolicHotKeyMode: UInt32(kHIHotKeyModeAllDisabled),
            registrationsHealthy: true,
            recoveryAllowed: true
        ))
        XCTAssertTrue(policy.shouldRegister(
            secureInputEnabled: false,
            symbolicHotKeyMode: UInt32(kHIHotKeyModeAllEnabled),
            registrationsHealthy: true,
            recoveryAllowed: true
        ))
    }

    func testRecoveryRequestSurvivesUntilRecoveryIsAllowed() {
        var policy = ShortcutRecoveryPolicy()

        policy.requestLifecycleRecovery()
        XCTAssertFalse(policy.shouldRegister(
            secureInputEnabled: false,
            symbolicHotKeyMode: UInt32(kHIHotKeyModeAllEnabled),
            registrationsHealthy: true,
            recoveryAllowed: false
        ))
        XCTAssertTrue(policy.shouldRegister(
            secureInputEnabled: false,
            symbolicHotKeyMode: UInt32(kHIHotKeyModeAllEnabled),
            registrationsHealthy: true,
            recoveryAllowed: true
        ))
    }

    func testRegistrationHealthRequiresEveryExpectedBinding() {
        let bindings = ShortcutRegistry.defaultBindings
        let registrations = bindings.map {
            GlobalShortcutRegistration(binding: $0, isRegistered: true, statusCode: noErr)
        }

        XCTAssertTrue(ShortcutRegistrationHealth.isHealthy(
            expectedBindings: bindings,
            registrations: registrations
        ))
        XCTAssertFalse(ShortcutRegistrationHealth.isHealthy(
            expectedBindings: bindings,
            registrations: Array(registrations.dropLast())
        ))

        var failed = registrations
        failed[0].isRegistered = false
        XCTAssertFalse(ShortcutRegistrationHealth.isHealthy(
            expectedBindings: bindings,
            registrations: failed
        ))
    }
}
