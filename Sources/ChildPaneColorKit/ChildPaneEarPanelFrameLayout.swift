import CoreGraphics
import Foundation

/// Screen-space frame for the collapsed-tab ear panel (pure geometry).
public enum ChildPaneEarPanelFrameLayout {
    public struct Inputs: Equatable {
        public var parentFrame: CGRect
        public var contentLayoutInScreen: CGRect
        public var visibleFrame: CGRect
        public var panelWidth: CGFloat
        public var panelHeight: CGFloat
        public var fullScreen: Bool

        public init(
            parentFrame: CGRect,
            contentLayoutInScreen: CGRect,
            visibleFrame: CGRect,
            panelWidth: CGFloat,
            panelHeight: CGFloat,
            fullScreen: Bool
        ) {
            self.parentFrame = parentFrame
            self.contentLayoutInScreen = contentLayoutInScreen
            self.visibleFrame = visibleFrame
            self.panelWidth = panelWidth
            self.panelHeight = panelHeight
            self.fullScreen = fullScreen
        }
    }

    public static func frame(for input: Inputs) -> CGRect {
        let content = input.contentLayoutInScreen
        let x: CGFloat = input.fullScreen ? content.maxX - input.panelWidth : input.parentFrame.maxX
        let contentTopY = content.maxY
        var y = contentTopY - input.panelHeight
        let bottom = content.minY
        if y < bottom { y = bottom }
        if y + input.panelHeight > contentTopY { y = contentTopY - input.panelHeight }

        var f = CGRect(x: x, y: y, width: input.panelWidth, height: input.panelHeight)
        if f.maxY > content.maxY { f.origin.y = content.maxY - f.height }
        if f.minY < content.minY { f.origin.y = content.minY }
        if f.maxY > input.visibleFrame.maxY { f.origin.y -= f.maxY - input.visibleFrame.maxY }
        if f.minY < input.visibleFrame.minY { f.origin.y = input.visibleFrame.minY }

        if input.fullScreen {
            if f.maxX > content.maxX { f.origin.x = content.maxX - f.width }
            if f.minX < content.minX { f.origin.x = content.minX }
        }
        if f.maxX > input.visibleFrame.maxX { f.origin.x = input.visibleFrame.maxX - f.width }
        if f.minX < input.visibleFrame.minX { f.origin.x = input.visibleFrame.minX }
        return f
    }
}