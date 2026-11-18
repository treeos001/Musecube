import CoreGraphics
import Foundation

public struct ChildPaneEarTabSizingResult: Equatable {
    public let tabHeight: CGFloat
    public let contentHeight: CGFloat
    public let panelHeight: CGFloat
    public let needsScroll: Bool

    public init(tabHeight: CGFloat, contentHeight: CGFloat, panelHeight: CGFloat, needsScroll: Bool) {
        self.tabHeight = tabHeight
        self.contentHeight = contentHeight
        self.panelHeight = panelHeight
        self.needsScroll = needsScroll
    }
}

public enum ChildPaneEarTabSizing {
    public static let defaultMinHeight: CGFloat = 44
    public static let defaultMaxHeight: CGFloat = 160
    public static let defaultBottomInset: CGFloat = 6

    /// `available` is vertical space for the tab stack (title-bar hairline to content bottom, excluding bottom inset).
    public static func uniformHeight(
        available: CGFloat,
        count: Int,
        min minH: CGFloat = defaultMinHeight,
        max maxH: CGFloat = defaultMaxHeight,
        bottomInset: CGFloat = defaultBottomInset
    ) -> ChildPaneEarTabSizingResult {
        guard count > 0, available > 0 else {
            return ChildPaneEarTabSizingResult(tabHeight: 0, contentHeight: 0, panelHeight: 0, needsScroll: false)
        }
        let ideal = available / CGFloat(count)
        let tabHeight = min(maxH, max(minH, ideal))
        let contentHeight = CGFloat(count) * tabHeight
        let needsScroll = contentHeight > available + 0.001
        let visibleStack = min(contentHeight, available)
        let panelHeight = visibleStack + bottomInset
        return ChildPaneEarTabSizingResult(
            tabHeight: tabHeight,
            contentHeight: contentHeight,
            panelHeight: panelHeight,
            needsScroll: needsScroll
        )
    }

    public static func stackContentHeight(tabHeight: CGFloat, count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return CGFloat(count) * tabHeight
    }
}