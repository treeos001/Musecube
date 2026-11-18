import CoreGraphics
import Foundation

public struct SidebarIconSizingResult: Equatable {
    public let iconSize: CGFloat
    public let cellHeight: CGFloat
    public let spacing: CGFloat
    public let needsScroll: Bool

    public init(iconSize: CGFloat, cellHeight: CGFloat, spacing: CGFloat, needsScroll: Bool) {
        self.iconSize = iconSize
        self.cellHeight = cellHeight
        self.spacing = spacing
        self.needsScroll = needsScroll
    }
}

public enum SidebarIconSizing {
    public static let defaultMaxIcon: CGFloat = 42
    public static let defaultMaxCellHeight: CGFloat = 64
    public static let defaultMaxSpacing: CGFloat = 0
    public static let defaultMinSpacing: CGFloat = 0

    /// Icon floor: 60% of max, but never below 24pt.
    public static var defaultMinIcon: CGFloat {
        max(24, defaultMaxIcon * 0.6)
    }

    private static var iconToCellRatio: CGFloat {
        defaultMaxCellHeight / defaultMaxIcon
    }

    public static func layout(
        availableHeight: CGFloat,
        count: Int,
        maxIcon: CGFloat = defaultMaxIcon,
        minIcon: CGFloat = defaultMinIcon,
        maxSpacing: CGFloat = defaultMaxSpacing,
        minSpacing: CGFloat = defaultMinSpacing
    ) -> SidebarIconSizingResult {
        let maxCell = maxIcon * iconToCellRatio
        let minCell = minIcon * iconToCellRatio
        let minScale = maxIcon > 0 ? minIcon / maxIcon : 1

        if count <= 0 {
            return SidebarIconSizingResult(
                iconSize: maxIcon,
                cellHeight: maxCell,
                spacing: maxSpacing,
                needsScroll: false
            )
        }

        guard availableHeight > 0, maxCell > 0 else {
            return SidebarIconSizingResult(
                iconSize: minIcon,
                cellHeight: minCell,
                spacing: minSpacing,
                needsScroll: count > 0
            )
        }

        let denom = CGFloat(count) * maxCell + CGFloat(max(0, count - 1)) * maxSpacing
        var scale: CGFloat = 1
        if denom > 0, stackHeight(count: count, cell: maxCell, spacing: maxSpacing) > availableHeight + 0.001 {
            scale = availableHeight / denom
            scale = min(1, max(minScale, scale))
        }

        let icon = maxIcon * scale
        let cell = maxCell * scale
        let spacing = maxSpacing * scale
        let minStack = stackHeight(count: count, cell: minCell, spacing: minSpacing)
        let needsScroll = minStack > availableHeight + 0.001

        return SidebarIconSizingResult(
            iconSize: icon,
            cellHeight: cell,
            spacing: spacing,
            needsScroll: needsScroll
        )
    }

    private static func stackHeight(count: Int, cell: CGFloat, spacing: CGFloat) -> CGFloat {
        CGFloat(count) * cell + CGFloat(max(0, count - 1)) * spacing
    }
}