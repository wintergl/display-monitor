import DisplayMonitorCore
import Foundation

final class SettingsStore {
    private let defaults: UserDefaults
    private let key = "DisplayMonitor.AppSettings"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> AppSettings {
        guard let data = defaults.data(forKey: key) else {
            return .safeDefault
        }
        do {
            let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
            let normalized = decoded.normalized
            if decoded != normalized {
                save(normalized)
            }
            return normalized
        } catch {
            return .safeDefault
        }
    }

    func save(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings.normalized) else {
            return
        }
        defaults.set(data, forKey: key)
    }
}
