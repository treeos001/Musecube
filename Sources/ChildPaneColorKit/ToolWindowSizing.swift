import CoreGraphics
import Foundation

public struct ToolWindowTarget: Equatable {
    public let frame: CGRect
    public let unchanged: Bool

    public init(frame: CGRect, unchanged: Bool) {
        self.frame = frame
        self.unchanged = unchanged
    }
}

public enum ToolWindowSizing {
    public static let defaultMaxContentWidth: CGFloat = 1000
    public static let defaultMaxContentHeight: CGFloat = 700
    public static let defaultVisibleWidthFactor: CGFloat = 0.85
    public static let defaultVisibleHeightFactor: CGFloat = 0.85
    public static let frameEqualityTolerance: CGFloat = 1

    /// Matches `AppDelegate` first-launch content rect (without child panes / auto-grow).
    public static func defaultContentSize(visibleFrame: CGRect) -> CGSize {
        CGSize(
            width: min(defaultMaxContentWidth, visibleFrame.width * defaultVisibleWidthFactor),
            height: min(defaultMaxContentHeight, visibleFrame.height * defaultVisibleHeightFactor)
        )
    }

    /// Target window frame: top-left fixed (AppKit `origin.x` + `maxY`), clamped into `visibleFrame`.
    /// `stored` is full window frame size when present; otherwise `defaultSize` (typically default frame size).
    public static func targetFrame(
        current: CGRect,
        stored: CGSize?,
        defaultSize: CGSize,
        visibleFrame: CGRect,
        minSize: CGSize = CGSize(width: 480, height: 360)
    ) -> ToolWindowTarget {
        var width = max(minSize.width, stored?.width ?? defaultSize.width)
        var height = max(minSize.height, stored?.height ?? defaultSize.height)
        width = min(width, visibleFrame.width)
        height = min(height, visibleFrame.height)

        let topLeftX = current.origin.x
        let topY = current.maxY
        var originX = topLeftX
        var originY = topY - height
        var frame = CGRect(x: originX, y: originY, width: width, height: height)

        if frame.maxX > visibleFrame.maxX {
            originX = visibleFrame.maxX - width
        }
        if originX < visibleFrame.minX {
            originX = visibleFrame.minX
        }
        if originY < visibleFrame.minY {
            originY = visibleFrame.minY
            height = min(height, topY - originY)
            height = max(minSize.height, height)
        }
        if topY > visibleFrame.maxY {
            originY = visibleFrame.maxY - height
        }

        frame = CGRect(x: originX, y: originY, width: width, height: height)

        if frame.width > visibleFrame.width {
            frame.size.width = visibleFrame.width
            frame.origin.x = visibleFrame.minX
        }
        if frame.height > visibleFrame.height {
            frame.size.height = visibleFrame.height
            frame.origin.y = visibleFrame.maxY - frame.height
        }

        let unchanged = framesApproximatelyEqual(current, frame, tolerance: frameEqualityTolerance)
        return ToolWindowTarget(frame: frame, unchanged: unchanged)
    }

    public static func framesApproximatelyEqual(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = frameEqualityTolerance) -> Bool {
        abs(a.origin.x - b.origin.x) <= tolerance
            && abs(a.origin.y - b.origin.y) <= tolerance
            && abs(a.width - b.width) <= tolerance
            && abs(a.height - b.height) <= tolerance
    }
}