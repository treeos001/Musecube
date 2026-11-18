import CoreGraphics
import Foundation

public enum ChildPaneLayoutMetrics {
    public static let minMainWidth: CGFloat = 360
    public static let minChildWidth: CGFloat = 320
    public static let compressedMinChildWidth: CGFloat = 260
    public static let userAdjustMinMainWidth: CGFloat = 240
    public static let userAdjustMinChildWidth: CGFloat = 200
    /// Main↔child split uses an overlay divider; no layout gutter.
    public static let mainChildSplitChrome: CGFloat = 0
    public static let columnDividerWidth: CGFloat = 1
    public static let earTabPanelWidth: CGFloat = 36
}

public struct ChildPaneLayoutResult: Equatable {
    public let mainWidth: CGFloat
    public let columnWidth: CGFloat
    public let columnWidths: [CGFloat]
    public let childGroupViewportWidth: CGFloat
    public let needsScroll: Bool
    public let requiredWindowGrowth: CGFloat

    public init(
        mainWidth: CGFloat,
        columnWidth: CGFloat,
        columnWidths: [CGFloat],
        childGroupViewportWidth: CGFloat,
        needsScroll: Bool,
        requiredWindowGrowth: CGFloat
    ) {
        self.mainWidth = mainWidth
        self.columnWidth = columnWidth
        self.columnWidths = columnWidths
        self.childGroupViewportWidth = childGroupViewportWidth
        self.needsScroll = needsScroll
        self.requiredWindowGrowth = requiredWindowGrowth
    }
}

public enum ChildPaneLayoutCapacity {
    public static func columnDividerTotalWidth(expandedCount: Int) -> CGFloat {
        guard expandedCount > 1 else { return 0 }
        return CGFloat(expandedCount - 1) * ChildPaneLayoutMetrics.columnDividerWidth
    }

    public static func minimumContentWidth(expandedCount: Int) -> CGFloat {
        guard expandedCount > 0 else { return 0 }
        let n = CGFloat(expandedCount)
        return ChildPaneLayoutMetrics.minMainWidth
            + ChildPaneLayoutMetrics.mainChildSplitChrome
            + n * ChildPaneLayoutMetrics.compressedMinChildWidth
            + columnDividerTotalWidth(expandedCount: expandedCount)
    }

    public static func layout(
        contentWidth: CGFloat,
        expandedCount: Int,
        splitRatio: CGFloat = 0.5
    ) -> ChildPaneLayoutResult {
        let nilPrefs = Array(repeating: CGFloat?.none, count: expandedCount)
        return layout(
            contentWidth: contentWidth,
            expandedCount: expandedCount,
            mainPreferred: nil,
            childPreferred: nilPrefs,
            splitRatio: splitRatio
        )
    }

    public static func layout(
        contentWidth: CGFloat,
        expandedCount: Int,
        mainPreferred: CGFloat?,
        childPreferred: [CGFloat?],
        splitRatio: CGFloat = 0.5
    ) -> ChildPaneLayoutResult {
        guard expandedCount > 0 else {
            return ChildPaneLayoutResult(
                mainWidth: max(0, contentWidth),
                columnWidth: 0,
                columnWidths: [],
                childGroupViewportWidth: 0,
                needsScroll: false,
                requiredWindowGrowth: 0
            )
        }

        let dividers = columnDividerTotalWidth(expandedCount: expandedCount)
        let minTotal = minimumContentWidth(expandedCount: expandedCount)
        let growth = max(0, minTotal - contentWidth)
        let needsScroll = contentWidth < minTotal

        let prefs = normalizedChildPreferences(childPreferred, count: expandedCount)
        let mainAdjusted = mainPreferred != nil
        let childMins = prefs.map { minChildWidth(userSet: $0 != nil) }
        let mainMinForLayout = minMainWidth(userSet: mainAdjusted, needsScroll: needsScroll)

        if needsScroll {
            let chrome = ChildPaneLayoutMetrics.mainChildSplitChrome
            let available = max(0, contentWidth - chrome)
            let n = CGFloat(expandedCount)
            let minCol = ChildPaneLayoutMetrics.compressedMinChildWidth
            let childContent = n * minCol + dividers
            var mainW = available - childContent
            if available >= ChildPaneLayoutMetrics.minMainWidth + minCol + ChildPaneLayoutMetrics.columnDividerWidth {
                mainW = ChildPaneLayoutMetrics.minMainWidth
            } else {
                mainW = max(0, available - childContent)
            }
            let viewport = max(0, available - mainW)
            let cols = Array(repeating: minCol, count: expandedCount)
            return ChildPaneLayoutResult(
                mainWidth: mainW,
                columnWidth: minCol,
                columnWidths: cols,
                childGroupViewportWidth: viewport,
                needsScroll: true,
                requiredWindowGrowth: growth
            )
        }

        let desired = resolvedDesiredWidths(
            contentWidth: contentWidth,
            expandedCount: expandedCount,
            dividers: dividers,
            mainPreferred: mainPreferred,
            childPreferred: prefs,
            splitRatio: splitRatio,
            mainAdjusted: mainAdjusted,
            childMins: childMins,
            mainMin: mainMinForLayout
        )

        let mainW = desired.main
        let cols = desired.children
        let childGroup = cols.reduce(0, +) + dividers
        let uniformCol = cols.first ?? 0

        return ChildPaneLayoutResult(
            mainWidth: mainW,
            columnWidth: uniformCol,
            columnWidths: cols,
            childGroupViewportWidth: childGroup,
            needsScroll: false,
            requiredWindowGrowth: growth
        )
    }

    /// Moves `delta` points from the right column to the left (divider dragged to the right).
    public static func adjustAdjacentPair(
        leftWidth: CGFloat,
        rightWidth: CGFloat,
        delta: CGFloat,
        leftMin: CGFloat,
        rightMin: CGFloat
    ) -> (CGFloat, CGFloat) {
        let sum = leftWidth + rightWidth
        var newLeft = leftWidth + delta
        newLeft = min(sum - rightMin, max(leftMin, newLeft))
        let newRight = sum - newLeft
        return (newLeft, newRight)
    }

    public static func evenPairDefault(leftWidth: CGFloat, rightWidth: CGFloat) -> (CGFloat, CGFloat) {
        let half = (leftWidth + rightWidth) / 2
        return (half, half)
    }

    public static func showsSplitPane(expandedChildCount: Int) -> Bool {
        expandedChildCount > 0
    }

    public static func isWideEarLayout(expandedChildCount: Int) -> Bool {
        expandedChildCount > 0
    }

    public static func earTabChildIDs(
        childOrder: [UUID],
        expanded: Set<UUID>
    ) -> [UUID] {
        childOrder.filter { !expanded.contains($0) }
    }

    public static func requiredWindowGrowth(
        contentWidth: CGFloat,
        expandedCount: Int
    ) -> CGFloat {
        max(0, minimumContentWidth(expandedCount: expandedCount) - contentWidth)
    }

    // MARK: - Private

    private static func normalizedChildPreferences(_ input: [CGFloat?], count: Int) -> [CGFloat?] {
        if input.count == count { return input }
        if input.count > count { return Array(input.prefix(count)) }
        return input + Array(repeating: nil, count: count - input.count)
    }

    private static func minChildWidth(userSet: Bool) -> CGFloat {
        userSet ? ChildPaneLayoutMetrics.userAdjustMinChildWidth : ChildPaneLayoutMetrics.compressedMinChildWidth
    }

    private static func minMainWidth(userSet: Bool, needsScroll: Bool) -> CGFloat {
        if needsScroll { return ChildPaneLayoutMetrics.minMainWidth }
        return userSet ? ChildPaneLayoutMetrics.userAdjustMinMainWidth : ChildPaneLayoutMetrics.minMainWidth
    }

    private struct DesiredWidths {
        var main: CGFloat
        var children: [CGFloat]
    }

    private static func resolvedDesiredWidths(
        contentWidth: CGFloat,
        expandedCount: Int,
        dividers: CGFloat,
        mainPreferred: CGFloat?,
        childPreferred: [CGFloat?],
        splitRatio: CGFloat,
        mainAdjusted: Bool,
        childMins: [CGFloat],
        mainMin: CGFloat
    ) -> DesiredWidths {
        let chrome = ChildPaneLayoutMetrics.mainChildSplitChrome
        let available = max(0, contentWidth - chrome)
        let cellsBudget = max(0, available - dividers)
        let n = CGFloat(expandedCount)

        let ratio = min(0.8, max(0.2, splitRatio))
        var mainW = mainPreferred ?? (cellsBudget * ratio)
        let childPrefsSet = childPreferred.compactMap { $0 }
        var childWs: [CGFloat]

        if childPrefsSet.count == expandedCount {
            childWs = childPreferred.map { $0! }
            if mainPreferred == nil {
                mainW = max(mainMin, cellsBudget - childWs.reduce(0, +))
            }
        } else if childPrefsSet.isEmpty {
            mainW = mainPreferred ?? (cellsBudget * ratio)
            let childBudget = max(0, cellsBudget - mainW)
            let each = childBudget / n
            childWs = Array(repeating: each, count: expandedCount)
            if mainPreferred == nil, mainW < mainMin {
                mainW = mainMin
                let childBudget = max(0, cellsBudget - mainW)
                let each = childBudget / n
                childWs = Array(repeating: each, count: expandedCount)
            }
        } else {
            mainW = mainPreferred ?? (cellsBudget * ratio)
            var remaining = max(0, cellsBudget - mainW)
            childWs = []
            var unset = 0
            for pref in childPreferred {
                if let p = pref {
                    childWs.append(p)
                    remaining -= p
                } else {
                    childWs.append(0)
                    unset += 1
                }
            }
            let share = unset > 0 ? remaining / CGFloat(unset) : 0
            for i in childPreferred.indices where childPreferred[i] == nil {
                childWs[i] = max(0, share)
            }
        }

        var widths = [mainW] + childWs
        let mins = [mainMin] + childMins
        let rawSum = widths.reduce(0, +)
        if rawSum > cellsBudget + 0.5 {
            widths = fitWidthsToBudget(widths, mins: mins, budget: cellsBudget)
        } else if rawSum < cellsBudget - 0.5 {
            let slack = cellsBudget - rawSum
            if childPreferred.allSatisfy({ $0 == nil }) && !mainAdjusted {
                widths[0] += slack
            } else if let lastUnset = childPreferred.lastIndex(where: { $0 == nil }), lastUnset + 1 < widths.count {
                widths[lastUnset + 1] += slack
            } else {
                widths[0] += slack
            }
        }
        widths = widths.enumerated().map { idx, w in max(mins[idx], w) }
        let afterClamp = widths.reduce(0, +)
        if afterClamp > cellsBudget + 0.5 {
            widths = fitWidthsToBudget(widths, mins: mins, budget: cellsBudget)
        }
        widths = normalizeSum(widths, mins: mins, budget: cellsBudget)

        let fittedMain = widths[0]
        let fittedChildren = Array(widths[1...])
        let colW = fittedChildren.first ?? 0
        _ = colW
        return DesiredWidths(main: fittedMain, children: fittedChildren)
    }

    private static func fitWidthsToBudget(_ widths: [CGFloat], mins: [CGFloat], budget: CGFloat) -> [CGFloat] {
        guard widths.count == mins.count, !widths.isEmpty else { return widths }
        var current = widths
        let sum = current.reduce(0, +)
        if sum <= budget + 0.001 { return normalizeSum(current, budget: budget) }

        var excess = sum - budget
        var slacks = zip(current, mins).map { max(0, $0 - $1) }
        let totalSlack = slacks.reduce(0, +)
        if totalSlack > 0.001 {
            for i in current.indices {
                let reduction = excess * (slacks[i] / totalSlack)
                current[i] = max(mins[i], current[i] - reduction)
            }
        } else {
            return mins
        }
        return normalizeSum(current, mins: mins, budget: budget)
    }

    private static func normalizeSum(_ widths: [CGFloat], mins: [CGFloat]? = nil, budget: CGFloat) -> [CGFloat] {
        var current = widths
        var sum = current.reduce(0, +)
        guard sum > 0.001 else { return current }
        if abs(sum - budget) <= 0.5 { return current }
        if sum > budget {
            let scale = budget / sum
            current = current.map { $0 * scale }
        } else {
            let scale = budget / sum
            current = current.map { $0 * scale }
        }
        if let mins {
            return fitWidthsToBudget(current, mins: mins, budget: budget)
        }
        return current
    }
}