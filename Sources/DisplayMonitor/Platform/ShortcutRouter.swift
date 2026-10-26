import Combine
import DisplayMonitorCore
import Foundation

@MainActor
protocol ShortcutRouting: AnyObject {
    var registrations: [GlobalShortcutRegistration] { get }

    func start(
        bindings: [ShortcutBinding],
        onCommand: @escaping (ToolSuiteCommand) -> Void
    )

    func stop()

    var hasSafeOptionChordRegistration: Bool { get }
}

@MainActor
final class ShortcutRouter: ObservableObject, ShortcutRouting {
    @Published private(set) var registrations: [GlobalShortcutRegistration] = []

    private let manager = GlobalShortcutManager()
    private var commandHandler: ((ToolSuiteCommand) -> Void)?

    func start(
        bindings: [ShortcutBinding] = ShortcutRegistry.defaultBindings,
        onCommand: @escaping (ToolSuiteCommand) -> Void
    ) {
        stop()
        commandHandler = onCommand

        var actions: [ToolSuiteCommand: @Sendable () -> Void] = [:]
        for binding in bindings {
            let command = binding.command
            actions[command] = { [weak self] in
                Task { @MainActor [weak self] in
                    self?.commandHandler?(command)
                }
            }
        }
        registrations = manager.register(
            bindings: bindings,
            actions: actions
        )
    }

    func stop() {
        manager.unregisterAll()
        registrations = []
        commandHandler = nil
    }

    var hasSafeOptionChordRegistration: Bool {
        let optionCommands: Set<ToolSuiteCommand> = [.toggleMonitor, .captureRegion]
        return optionCommands.allSatisfy { command in
            registrations.contains {
                $0.shortcut == command && $0.isRegistered
            }
        }
    }
}
