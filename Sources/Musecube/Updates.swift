import AppKit

/// Feedback / takedown entry (Help menu + store footer). Does nothing but explain while the URL is a placeholder.
@MainActor func openIssues() {
    guard IssuesConfig.isConfigured, let u = URL(string: IssuesConfig.url) else {
        let a = NSAlert()
        a.messageText = L("反馈入口还没有配置")
        a.informativeText = L("反馈地址会在项目仓库确定后填上。")
        a.addButton(withTitle: L("好"))
        a.runModal()
        return
    }
    NSWorkspace.shared.open(u)
}

#if canImport(Sparkle) && !APPSTORE
import Sparkle

/// Sparkle auto-update, direct (website) edition only. The App Store edition does not link Sparkle at all.
/// While SUFeedURL / SUPublicEDKey in Info.plist are placeholders, the updater is never created:
/// no automatic checks and no network requests.
@MainActor enum Updates {
    static let feedPlaceholder = "https://example.invalid/REPLACE_ME/appcast.xml"
    static let keyPlaceholder = "REPLACE_WITH_EDDSA_PUBLIC_KEY"

    static var isConfigured: Bool {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let feed = info["SUFeedURL"] as? String, let key = info["SUPublicEDKey"] as? String else { return false }
        return feed != feedPlaceholder && key != keyPlaceholder && feed.hasPrefix("https://") && !key.isEmpty
    }

    private static var controller: SPUStandardUpdaterController?

    /// Call once at launch. Starts Sparkle only when configured.
    static func setUp() {
        guard isConfigured, controller == nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    static func checkForUpdates() {
        if let c = controller { c.checkForUpdates(nil); return }
        let a = NSAlert()
        a.messageText = L("自动更新还没有配置")
        a.informativeText = L("自动更新还没有打开。App 不会在后台检查更新，新版本以项目发布为准。")
        a.addButton(withTitle: L("好"))
        a.runModal()
    }
}
#endif
