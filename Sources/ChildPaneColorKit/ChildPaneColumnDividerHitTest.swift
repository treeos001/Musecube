import CoreGraphics
import Foundation

public enum ChildPaneColumnDividerHitTest {
  public static let grabHalfWidth: CGFloat = 4
  public static let grabWidth: CGFloat = grabHalfWidth * 2

  /// Center x of the main↔first-child divider in the main content coordinate space.
  public static func mainChildDividerCenterX(mainWidth: CGFloat) -> CGFloat {
    mainWidth - ChildPaneLayoutMetrics.columnDividerWidth / 2
  }

  /// Center x positions of dividers between child columns, in the child HStack coordinate space.
  public static func childGroupDividerCenterXs(columnWidths: [CGFloat]) -> [CGFloat] {
    guard columnWidths.count >= 2 else { return [] }
    var centers: [CGFloat] = []
    var leading: CGFloat = 0
    for i in 0..<(columnWidths.count - 1) {
      leading += columnWidths[i]
      centers.append(leading + ChildPaneLayoutMetrics.columnDividerWidth / 2)
      leading += ChildPaneLayoutMetrics.columnDividerWidth
    }
    return centers
  }

  /// Returns the index of the divider at `x` when `|x − center| ≤ halfWidth`.
  public static func dividerIndex(
    atX x: CGFloat,
    centers: [CGFloat],
    halfWidth: CGFloat = grabHalfWidth
  ) -> Int? {
    for (index, center) in centers.enumerated() where abs(x - center) <= halfWidth {
      return index
    }
    return nil
  }
}