import Foundation

public enum ArtifactDiskCapacity {
    /// Some volumes return a non-nil zero for the important-usage estimate
    /// while ordinary available capacity remains positive. Do not let that
    /// estimate hide confirmed free space; unknown/negative values add none.
    public static func availableBytes(importantUsage: Int64?, ordinary: Int64?) -> Int64 {
        max(0, importantUsage ?? 0, ordinary ?? 0)
    }
}
