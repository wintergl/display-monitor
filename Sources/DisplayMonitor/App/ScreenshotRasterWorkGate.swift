import Foundation

/// Serializes source-image decoding across preview and export workers. A PNG
/// decoder can transiently materialize the complete source even for a crop.
/// Call this synchronous scope from a background worker, never while waiting
/// on the main actor. Recursive use lets an export renderer call its own
/// bounded filter renderer inside the same permit without deadlocking.
final class ScreenshotRasterWorkGate: @unchecked Sendable {
    static let shared = ScreenshotRasterWorkGate()
    private let lock = NSRecursiveLock()

    func withPermit<Value>(_ work: () throws -> Value) rethrows -> Value {
        lock.lock()
        defer { lock.unlock() }
        return try work()
    }
}
