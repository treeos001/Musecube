import Foundation

public enum ChildPanePopupDockPolicy {
  /// Context-menu “open in new window” should dock unless the URL is auth or payment (checked separately).
  public static func shouldDockContextMenuNewWindow(isAuthURL: Bool, isPaymentURL: Bool) -> Bool {
    if isAuthURL || isPaymentURL { return false }
    return true
  }

  /// WebKit often uses `.other` with no target frame for context-menu new-window navigations.
  public static func resemblesContextMenuWindowRequest(
    hasTargetFrame: Bool,
    navigationTypeIsOther: Bool,
    contextMenuDockPending: Bool
  ) -> Bool {
    contextMenuDockPending && !hasTargetFrame && navigationTypeIsOther
  }
}