import Carbon.HIToolbox
import Foundation

struct ShortcutRecoveryPolicy {
    private var secureInputWasEnabled: Bool?
    private var previousSymbolicHotKeyMode: UInt32?
    private var recoveryPending = false

    mutating func requestLifecycleRecovery() {
        recoveryPending = true
    }

    mutating func shouldRegister(
        secureInputEnabled: Bool,
        symbolicHotKeyMode: UInt32,
        registrationsHealthy: Bool,
        recoveryAllowed: Bool
    ) -> Bool {
        let secureInputWasReleased = secureInputWasEnabled == true && !secureInputEnabled
        secureInputWasEnabled = secureInputEnabled
        let symbolicHotKeysWereReenabled = previousSymbolicHotKeyMode.map {
            $0 != UInt32(kHIHotKeyModeAllEnabled)
                && symbolicHotKeyMode == UInt32(kHIHotKeyModeAllEnabled)
        } ?? false
        previousSymbolicHotKeyMode = symbolicHotKeyMode

        if secureInputWasReleased || symbolicHotKeysWereReenabled || !registrationsHealthy {
            recoveryPending = true
        }

        guard recoveryAllowed,
              !secureInputEnabled,
              symbolicHotKeyMode == UInt32(kHIHotKeyModeAllEnabled) else {
            return false
        }
        guard recoveryPending else {
            return false
        }

        recoveryPending = false
        return true
    }
}

enum ShortcutRegistrationHealth {
    static func isHealthy(
        expectedBindings: [ShortcutBinding],
        registrations: [GlobalShortcutRegistration]
    ) -> Bool {
        guard registrations.count == expectedBindings.count else {
            return false
        }
        return expectedBindings.allSatisfy { expected in
            registrations.contains {
                $0.binding == expected && $0.isRegistered
            }
        }
    }
}
