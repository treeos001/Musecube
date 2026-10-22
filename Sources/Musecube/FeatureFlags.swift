import Foundation

/// Edition switches. Direct (website) edition is the default; the Mac App Store edition is compiled with -D APPSTORE.
enum FeatureFlags {
    /// Phase-1 switch. Set simplifyEnabled = true to restore simplify/pick features (code kept intact).
    static let simplifyEnabled = false
    #if APPSTORE
    static let isAppStore = true
    static let showDonationLinks = false
    static let donationURL: URL? = nil
    #else
    static let isAppStore = false
    static let showDonationLinks = true
    static let donationURL: URL? = URL(string: "https://ko-fi.com/shukuinan")
    #endif

}

/// Public feedback / takedown requests (GitHub Issues).
enum IssuesConfig {
    static let placeholder = "https://github.com/OWNER/REPO/issues"
    static let url = "https://github.com/treeos001/Musecube/issues"
    static var isConfigured: Bool { url != placeholder && URL(string: url) != nil }
}

/// Feedback channel for “报告这个工具有问题” (R6). Empty = the mail app opens with no recipient filled in.
enum FeedbackConfig {
    static let email = ""
}
