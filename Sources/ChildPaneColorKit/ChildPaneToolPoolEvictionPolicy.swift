import Foundation

/// Which background tool pages may be LRU-trimmed (`WebController.trim`).
public enum ChildPaneToolPoolEvictionPolicy {
    /// `memoryPressure == true` when `trim` is driven by memory warning (`limit == 1`).
    public static func isEligibleForEviction(
        toolID: UUID,
        currentToolID: UUID?,
        isPinned: Bool,
        keepsRunningInBackground: Bool,
        memoryPressure: Bool
    ) -> Bool {
        if toolID == currentToolID { return false }
        if isPinned { return false }
        if keepsRunningInBackground, !memoryPressure { return false }
        return true
    }
}