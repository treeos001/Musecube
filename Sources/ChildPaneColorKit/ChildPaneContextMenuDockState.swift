import Foundation

/// Pure state for context-menu「在新窗口打开」→ docked-child readiness (default 10s).
public struct ChildPaneContextMenuDockState: Equatable {
    public var timeout: TimeInterval
    private var armedAt: [ObjectIdentifier: Date] = [:]

    public init(timeout: TimeInterval = 10) {
        self.timeout = timeout
    }

    public mutating func arm(webView: ObjectIdentifier, at date: Date) {
        armedAt[webView] = date
    }

    public func isPending(webView: ObjectIdentifier, at date: Date) -> Bool {
        guard let start = armedAt[webView] else { return false }
        return date.timeIntervalSince(start) < timeout
    }

    @discardableResult
    public mutating func consume(webView: ObjectIdentifier) -> Bool {
        armedAt.removeValue(forKey: webView) != nil
    }

    @discardableResult
    public mutating func disarm(webView: ObjectIdentifier) -> Bool {
        armedAt.removeValue(forKey: webView) != nil
    }

    public func expiredWebViews(at date: Date) -> [ObjectIdentifier] {
        armedAt.filter { date.timeIntervalSince($0.value) >= timeout }.map(\.key)
    }
}