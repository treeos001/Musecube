import Foundation

public enum ChildPaneDockURLPolicy {
    /// Popup floats (not docked) when size is strictly below these thresholds (`<`, never `≤`).
    /// `nil` width/height skips that axis; `0` counts as below threshold when the value is present.
    public struct PopupSizeThresholds: Equatable {
        public let bothUnderWidth: CGFloat
        public let bothUnderHeight: CGFloat
        public let widthOnlyUnder: CGFloat
        public let heightOnlyUnder: CGFloat

        public init(
            bothUnderWidth: CGFloat,
            bothUnderHeight: CGFloat,
            widthOnlyUnder: CGFloat,
            heightOnlyUnder: CGFloat
        ) {
            self.bothUnderWidth = bothUnderWidth
            self.bothUnderHeight = bothUnderHeight
            self.widthOnlyUnder = widthOnlyUnder
            self.heightOnlyUnder = heightOnlyUnder
        }

        public static let `default` = PopupSizeThresholds(
            bothUnderWidth: 300,
            bothUnderHeight: 300,
            widthOnlyUnder: 250,
            heightOnlyUnder: 200
        )
    }

    public typealias PopupThresholds = PopupSizeThresholds

    public static let popupThresholds: PopupThresholds = .default

    public static func shouldDockPopup(
        url: URL?,
        width: CGFloat?,
        height: CGFloat?,
        fromContextMenu: Bool = false,
        thresholds: PopupThresholds = popupThresholds
    ) -> Bool {
        guard let url else { return true }
        if isAuthURL(url) { return false }
        if isPaymentURL(url) { return false }
        if fromContextMenu {
            return ChildPanePopupDockPolicy.shouldDockContextMenuNewWindow(isAuthURL: false, isPaymentURL: false)
        }
        if treatsAsFloatingPopup(width: width, height: height, thresholds: thresholds) { return false }
        return true
    }

    public static func treatsAsFloatingPopup(
        width: CGFloat?,
        height: CGFloat?,
        thresholds: PopupThresholds = popupThresholds
    ) -> Bool {
        if let w = width, let h = height, w < thresholds.bothUnderWidth && h < thresholds.bothUnderHeight {
            return true
        }
        if let w = width, w < thresholds.widthOnlyUnder { return true }
        if let h = height, h < thresholds.heightOnlyUnder { return true }
        return false
    }

    public static func isAuthURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let authHosts = [
            "accounts.google.com",
            "login.microsoftonline.com",
            "login.live.com",
            "appleid.apple.com",
            "github.com/login",
            "github.com/sessions",
            "auth0.com",
            "okta.com",
            "onelogin.com",
            "duosecurity.com",
        ]
        for ah in authHosts {
            if ah.contains("/") {
                let parts = ah.split(separator: "/", maxSplits: 1)
                if host == parts[0] || host.hasSuffix("." + parts[0]) {
                    if url.path.lowercased().hasPrefix("/" + parts[1]) { return true }
                }
            } else {
                if host == ah || host.hasSuffix("." + ah) { return true }
            }
        }
        let authPaths = ["/oauth", "/authorize", "/auth/", "/login", "/signin", "/sso/"]
        let lowerPath = url.path.lowercased()
        for ap in authPaths {
            if lowerPath.contains(ap) { return true }
        }
        return false
    }

    public static func isPaymentURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let paymentHosts = [
            "checkout.stripe.com",
            "paypal.com",
            "pay.google.com",
            "paddle.com",
            "gumroad.com",
            "lemonsqueezy.com",
            "buy.stripe.com",
        ]
        for ph in paymentHosts {
            if host == ph || host.hasSuffix("." + ph) { return true }
        }
        let paymentPaths = ["/checkout", "/payment", "/pay/", "/billing/"]
        let lowerPath = url.path.lowercased()
        for pp in paymentPaths {
            if lowerPath.contains(pp) { return true }
        }
        return false
    }
}