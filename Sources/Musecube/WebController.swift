import AppKit
import WebKit

typealias AppWebView = WKWebView

/// Weak proxy so WKUserContentController doesn't retain the controller.
final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ t: WKScriptMessageHandler) { target = t }
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(c, didReceive: message)
    }
}

final class WebController: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate,
    WKScriptMessageHandler {

    /// The web view of the currently selected tool. Each tool owns its own WKWebView so
    /// switching tools keeps page state (input text, scroll, uploaded files).
    @Published private(set) var webView: WKWebView
    let rules: RuleStore

    @Published var simplified = true { didSet { if oldValue != simplified { applyCurrent() } } }
    @Published var picking = false
    @Published var ruleMissing = false
    @Published var hasRule = false
    @Published var toast: String?

    /// How many tool pages stay alive in memory (most recently used first), scaled to the Mac's RAM.
    static let keepAlive: Int = {
        let gb = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        return gb <= 8.5 ? 3 : (gb <= 16.5 ? 5 : 8)
    }()
    /// Tools the user pinned to stay alive in the background (not counted against keepAlive).
    @Published private(set) var pinned: Set<UUID> =
        Set((UserDefaults.standard.stringArray(forKey: "pinnedTools") ?? []).compactMap { UUID(uuidString: $0) })
    @Published var progress: Double = 1
    @Published var isLoading = false
    @Published var loadError: String?
    @Published var findVisible = false
    @Published var findNoMatch = false
    private var savedState: [UUID: Any] = [:]
    private var errors: [UUID: String] = [:]
    enum ErrorKind { case offline, certificate, other }
    private var errorKinds: [UUID: ErrorKind] = [:]
    /// Kind of the error shown for the current tool (drives the native error page).
    @Published private(set) var loadErrorKind: ErrorKind?
    private var failedURLs: [UUID: URL] = [:]
    private var crashed: Set<UUID> = []
    private var progressObs: [NSKeyValueObservation] = []
    private var memSource: DispatchSourceMemoryPressure?
    private var pool: [UUID: WKWebView] = [:]
    private var lru: [UUID] = []
    private var popups: [NSWindow] = []
    /// Which tool a web view (tool page or popup) belongs to, and each tool's home URL.
    private var owner: [ObjectIdentifier: UUID] = [:]
    private var toolURLs: [UUID: String] = [:]
    private var currentToolID: UUID?
    private var toolNames: [UUID: String] = [:]

    init(rules: RuleStore) {
        self.rules = rules
        self.webView = WKWebView(frame: .zero)
        super.init()
        DownloadManager.shared.fallbackWebView = { [weak self] in self?.webView }
        // Under memory pressure keep only the current and pinned tools alive.
        let src = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        src.setEventHandler { [weak self] in self?.trim(limit: 1) }
        src.resume()
        memSource = src
    }

    func isPinned(_ id: UUID) -> Bool { pinned.contains(id) }
    func togglePinned(_ id: UUID) {
        if pinned.contains(id) { pinned.remove(id) } else { pinned.insert(id) }
        UserDefaults.standard.set(pinned.map { $0.uuidString }, forKey: "pinnedTools")
        trim()
    }

    private func trim(limit: Int = WebController.keepAlive) {
        while true {
            // Background-running tools (timers) are not evicted by the normal LRU, only under memory pressure.
            let unpinned = lru.filter { !pinned.contains($0) && (limit == 1 || !(knownTools[$0].map { keepsRunningInBackground($0.url) } ?? false)) }
            guard unpinned.count > limit, let old = unpinned.last(where: { $0 != currentToolID }) else { break }
            evict(old)
        }
    }

    /// Close a background page but remember its scroll position and back/forward history.
    private func evict(_ id: UUID) {
        lru.removeAll { $0 == id }
        if let wv = pool.removeValue(forKey: id) {
            if let st = wv.interactionState { savedState[id] = st }
            wv.stopLoading()
            owner.removeValue(forKey: ObjectIdentifier(wv))
            pageEvent(.closed, wv)
        }
    }

    enum PageEvent { case opened, activated, closed, changed }
    /// Page lifecycle hook. Does nothing in this build.
    func pageEvent(_ e: PageEvent, _ wv: WKWebView) {
    }

    private func observeProgress() {
        let wv = webView
        progress = wv.estimatedProgress
        isLoading = wv.isLoading
        progressObs = [
            wv.observe(\.estimatedProgress, options: [.new]) { [weak self] w, _ in
                DispatchQueue.main.async { if self?.webView === w { self?.progress = w.estimatedProgress } }
            },
            wv.observe(\.isLoading, options: [.new]) { [weak self] w, _ in
                DispatchQueue.main.async { if self?.webView === w { self?.isLoading = w.isLoading } }
            },
        ]
    }

    // MARK: - Navigation commands

    func goBack() { if webView.canGoBack { webView.goBack() } }
    func goForward() { if webView.canGoForward { webView.goForward() } }
    func reload() { if loadError != nil { retry() } else { webView.reload() } }

    func retry() {
        guard let id = currentToolID else { return }
        errors.removeValue(forKey: id); errorKinds.removeValue(forKey: id)
        loadError = nil; loadErrorKind = nil
        let u = failedURLs.removeValue(forKey: id) ?? toolURLs[id].flatMap { URL(string: $0) }
        if let u = u { webView.load(URLRequest(url: u)) } else { webView.reload() }
    }

    private func zoom(for id: UUID) -> CGFloat {
        let z = UserDefaults.standard.double(forKey: "zoom.\(id.uuidString)")
        return z > 0 ? CGFloat(z) : 1
    }
    func setZoom(_ z: CGFloat) {
        guard let id = currentToolID else { return }
        let v = min(3, max(0.5, (z * 10).rounded() / 10))
        webView.pageZoom = v
        UserDefaults.standard.set(Double(v), forKey: "zoom.\(id.uuidString)")
        showToast(String(format: L("缩放 %d%%"), Int((v * 100).rounded())))
    }
    func zoomIn() { setZoom(webView.pageZoom + 0.1) }
    func zoomOut() { setZoom(webView.pageZoom - 0.1) }
    func zoomReset() { setZoom(1) }

    func find(_ text: String, backwards: Bool = false) {
        guard !text.isEmpty else { findNoMatch = false; return }
        let c = WKFindConfiguration()
        c.backwards = backwards
        c.caseSensitive = false
        c.wraps = true
        webView.find(text, configuration: c) { [weak self] r in self?.findNoMatch = !r.matchFound }
    }

    /// One persistent data store per site (domainKey): entries of one site share it; different sites stay isolated.
    private var dataStores: [UUID: WKWebsiteDataStore] = [:]
    private func dataStore(for id: UUID) -> WKWebsiteDataStore {
        if let s = dataStores[id] { return s }
        let s = WKWebsiteDataStore(forIdentifier: id) // persistent on disk, survives restart
        dataStores[id] = s
        return s
    }

    /// Wipe this site's cookies / site data (every tool that shares the store) and reload open pages.
    func clearData(for tool: Tool) {
        let store = dataStore(for: tool.storeID)
        let pages = knownTools.values.filter { $0.storeID == tool.storeID }
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { [weak self] in
            guard let self = self else { return }
            for t in pages {
                if let wv = self.pool[t.id], let u = URL(string: t.url) { wv.load(URLRequest(url: u)) }
            }
            for w in self.popups {
                guard let wv = w.contentView as? WKWebView, wv.configuration.websiteDataStore === store, let u = wv.url else { continue }
                wv.load(URLRequest(url: u))
            }
            self.showToast(String(format: L("已清除“%@”所在网站的登录和网站数据"), tool.name))
        }
    }

    /// Delete a tool's data store from disk (tool was deleted).
    func removeDataStore(for tool: Tool) {
        forget(tool.id)
        for w in popups where (w.contentView as? WKWebView)?.configuration.websiteDataStore === dataStores[tool.storeID] { w.close() }
        dataStores.removeValue(forKey: tool.storeID)
        let sid = tool.storeID
        // Give WebKit a moment to release the web views using it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            WKWebsiteDataStore.remove(forIdentifier: sid) { err in
                if let err = err { NSLog("Musecube: remove data store failed: %@", "\(err)") }
            }
        }
    }

    /// Store preview page: the added tool's own data store, or a non-persistent one for tools not added yet.
    func makePreviewWebView(url: URL, storeID: UUID?) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.isFraudulentWebsiteWarningEnabled = true
        config.websiteDataStore = storeID.map { dataStore(for: $0) } ?? .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.applicationNameForUserAgent = SiteMeta.appUA
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = self // HTTPS-only policy, Google sign-in handling
        wv.uiDelegate = self         // file upload panel, pop-ups, downloads
        wv.load(URLRequest(url: url))
        return wv
    }

    private func makeWebView(storeID: UUID, toolID: UUID? = nil, url: String? = nil) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.isFraudulentWebsiteWarningEnabled = true
        config.websiteDataStore = dataStore(for: storeID)
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        // Per tool only: catalog tools flagged keeps_running_in_background (timers) are not throttled
        // when hidden/occluded/minimized. Every other tool keeps WebKit's default policy.
        if let url = url, keepsRunningInBackground(url) {
            if #available(macOS 14.0, *) { config.preferences.inactiveSchedulingPolicy = .none }
        }
        let ucc = WKUserContentController()
        if FeatureFlags.simplifyEnabled {
            ucc.addUserScript(WKUserScript(source: Scripts.core, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        ucc.add(WeakScriptHandler(self), name: "wtb")
        // Narrow download helper: only turns window.open(blob:/data:) into a native download.
        ucc.addUserScript(WKUserScript(source: Scripts.downloadHelper, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        ucc.add(WeakScriptHandler(self), name: "wtbdl")
        config.userContentController = ucc
        config.applicationNameForUserAgent = SiteMeta.appUA
        let wv = AppWebView(frame: .zero, configuration: config)
        wv.allowsBackForwardNavigationGestures = true
        wv.navigationDelegate = self
        wv.uiDelegate = self
        pageEvent(.opened, wv)
        return wv
    }

    private var knownTools: [UUID: Tool] = [:]
    /// URL of every tool page seen this session.
    var toolURLMap: [UUID: String] { toolURLs }

    /// Re-create a tool's page, keeping history and scroll position.
    func rebuildPage(_ id: UUID) {
        guard let wv = pool[id] else { return }
        if let st = wv.interactionState { savedState[id] = st }
        let wasCurrent = currentToolID == id
        pool.removeValue(forKey: id); wv.stopLoading()
        owner.removeValue(forKey: ObjectIdentifier(wv)); pageEvent(.closed, wv)
        lru.removeAll { $0 == id }
        if wasCurrent, let t = knownTools[id] { currentToolID = nil; load(t) }
    }

    /// Drop a tool's page (e.g. the tool was deleted).
    func forget(_ id: UUID) {
        if let wv = pool.removeValue(forKey: id) { wv.stopLoading(); owner.removeValue(forKey: ObjectIdentifier(wv)); pageEvent(.closed, wv) }
        lru.removeAll { $0 == id }
        savedState.removeValue(forKey: id); errors.removeValue(forKey: id); errorKinds.removeValue(forKey: id)
        failedURLs.removeValue(forKey: id); crashed.remove(id)
        if currentToolID == id { currentToolID = nil }
    }

    // MARK: - Loading

    func load(_ tool: Tool?) {
        guard let tool = tool, let url = URL(string: tool.url) else {
            currentToolID = nil
            webView = WKWebView(frame: .zero)
            return
        }
        toolURLs[tool.id] = tool.url
        toolNames[tool.id] = tool.name
        knownTools[tool.id] = tool
        if currentToolID == tool.id { return }
        stopPicking(reapply: false)
        let previousID = currentToolID
        currentToolID = tool.id
        ruleMissing = false
        hasRule = FeatureFlags.simplifyEnabled && rules.rule(for: domainKey(for: url)) != nil
        lru.removeAll { $0 == tool.id }
        lru.insert(tool.id, at: 0)
        let previous = webView
        if let existing = pool[tool.id] {
            webView = existing
        } else {
            let wv = makeWebView(storeID: tool.storeID, toolID: tool.id, url: tool.url)
            pool[tool.id] = wv
            owner[ObjectIdentifier(wv)] = tool.id
            wv.pageZoom = zoom(for: tool.id)
            webView = wv
            if let st = savedState.removeValue(forKey: tool.id) {
                wv.interactionState = st // restores history and scroll, reloads the page
            } else {
                wv.load(URLRequest(url: url))
            }
        }
        // Background tools stop playing audio / video.
        // Pinned tools (e.g. a metronome) keep playing in the background.
        if previous !== webView, !(previousID.map { pinned.contains($0) } ?? false) {
            previous.pauseAllMediaPlayback(completionHandler: nil)
            previous.setAllMediaPlaybackSuspended(true, completionHandler: nil)
        }
        webView.setAllMediaPlaybackSuspended(false, completionHandler: nil)
        pageEvent(.activated, webView)
        loadError = errors[tool.id]
        loadErrorKind = errorKinds[tool.id]
        // Switched back to a tool that failed while offline, and the network is back: retry right away.
        if errorKinds[tool.id] == .offline, NetworkMonitor.shared.online { retry() }
        findNoMatch = false
        observeProgress()
        if crashed.remove(tool.id) != nil { webView.reload() }
        trim()
    }

    /// Sign-in pages that refuse embedded web views (Google blocks them outright).
    static let externalAuthHosts = ["accounts.google.com"]
    static func needsExternalBrowser(_ url: URL?) -> Bool {
        guard let h = url?.host?.lowercased() else { return false }
        return externalAuthHosts.contains { h == $0 || h.hasSuffix("." + $0) }
    }

    var currentDomain: String? { domainKey(for: webView.url) }

    func applyCurrent() {
        guard FeatureFlags.simplifyEnabled else { hasRule = false; ruleMissing = false; return }
        let rule = rules.rule(for: currentDomain)
        hasRule = rule != nil
        if simplified, let r = rule, !picking {
            ruleMissing = false
            webView.evaluateJavaScript("window.__wtb && window.__wtb.apply(\(jsString(r)))", completionHandler: nil)
        } else {
            ruleMissing = false
            webView.evaluateJavaScript("window.__wtb && window.__wtb.remove()", completionHandler: nil)
        }
    }

    func startPicking() {
        guard FeatureFlags.simplifyEnabled else { return }
        picking = true
        ruleMissing = false
        webView.evaluateJavaScript("window.__wtb && (window.__wtb.remove(), window.__wtb.startPick())", completionHandler: nil)
        webView.window?.makeFirstResponder(webView)
    }

    func stopPicking(reapply: Bool = true) {
        guard picking else { return }
        picking = false
        webView.evaluateJavaScript("window.__wtb && window.__wtb.stopPick()", completionHandler: nil)
        if reapply { applyCurrent() }
    }

    func clearUserRule() {
        guard let d = currentDomain else { return }
        rules.clear(d)
        applyCurrent()
    }

    private func jsString(_ s: String) -> String {
        if let d = try? JSONSerialization.data(withJSONObject: [s]), let a = String(data: d, encoding: .utf8) {
            return String(a.dropFirst().dropLast()) // strip [ ]
        }
        return "\"\""
    }

    private func showToast(_ s: String) {
        toast = s
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.toast == s { self?.toast = nil }
        }
    }

    // MARK: - Script messages

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "wtbdl" { handleDownloadMessage(message); return }
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "picked":
            guard let sel = body["selector"] as? String, let d = currentDomain else { return }
            rules.set(sel, for: d)
            picking = false
            if simplified { applyCurrent() } else { simplified = true }
            showToast(String(format: L("已为 %@ 保存精简规则"), d))
        case "pickCancel":
            picking = false
            applyCurrent()
        case "ruleStatus":
            let found = (body["found"] as? Bool) ?? true
            ruleMissing = simplified && hasRule && !picking && !found
        default: break
        }
    }

    // MARK: - HTTPS only

    static func isInsecure(_ url: URL?) -> Bool {
        guard let u = url else { return false }
        return u.scheme?.lowercased() == "http" && !isLocalHost(u.host)
    }

    /// Schemes a tool page is allowed to navigate to. Anything else is cancelled.
    static func schemeAllowed(_ url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        switch scheme {
        case "https", "http", "about", "blob", "data": return true
        default: return false
        }
    }

    private func warnInsecure(_ url: URL) {
        DispatchQueue.main.async {
            let a = NSAlert()
            a.messageText = L("已阻止不安全的网页（http）")
            a.informativeText = L("Musecube 只打开 https 网页，以保护你的登录信息。") + "\n" + url.absoluteString
            a.alertStyle = .warning
            a.addButton(withTitle: L("在系统浏览器打开"))
            a.addButton(withTitle: L("取消"))
            if a.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
        }
    }

    /// Page to hand to the system browser: the tool's own address, the page on screen, or the blocked Google URL.
    private func browserURL(for webView: WKWebView, blocked: URL?) -> URL? {
        if let id = owner[ObjectIdentifier(webView)],
           let s = toolURLs[id], let u = URL(string: s) { return u }
        if let u = webView.url, u.scheme?.lowercased() == "https", !Self.needsExternalBrowser(u) { return u }
        if let u = blocked, u.scheme?.lowercased() == "https" { return u }
        return nil
    }

    /// Google blocks sign-in inside embedded web views: explain and offer the tool in the browser.
    private func handleGoogleSignIn(from webView: WKWebView, blocked: URL?) {
        let openURL = browserURL(for: webView, blocked: blocked)
        if let win = popups.first(where: { $0.contentView === webView }) { win.close() }
        DispatchQueue.main.async {
            let a = NSAlert()
            a.messageText = L("Google 不允许在 App 内登录")
            var text = L("可以改用邮箱、Apple 或 GitHub 登录，也可以在浏览器里使用这个工具。")
            if let u = openURL, let d = domainKey(for: u), !Self.needsExternalBrowser(u),
               let note = Catalog.shared.first(where: { domainKey(for: URL(string: $0.url)) == d })?.login_note,
               !note.isEmpty {
                text += "\n\n" + note
            }
            a.informativeText = text
            a.addButton(withTitle: L("在浏览器里使用"))
            a.addButton(withTitle: L("继续在 App 中使用"))
            guard a.runModal() == .alertFirstButtonReturn, let u = openURL else { return }
            DispatchQueue.main.async {
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.activates = true
                NSWorkspace.shared.open(u, configuration: cfg, completionHandler: nil)
            }
        }
    }

    // MARK: - Navigation

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        setError(webView, error)
    }
    /// Failure after the page committed (it is already on screen): log only, never cover the page.
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let e = error as NSError
        NSLog("Musecube: post-commit failure %@ %d %@", e.domain, e.code, "\(e.userInfo[NSURLErrorFailingURLErrorKey] ?? webView.url as Any)")
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { setError(webView, nil) }

    /// Web content process crashed or was reclaimed by the system: reload instead of a blank page.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let id = owner[ObjectIdentifier(webView)], pool[id] === webView else { webView.reload(); return }
        if id == currentToolID {
            webView.reload()
            showToast(L("页面意外退出，已自动重新载入"))
        } else {
            crashed.insert(id)
        }
    }

    private func setError(_ wv: WKWebView, _ error: Error?) {
        guard let id = owner[ObjectIdentifier(wv)], pool[id] === wv else { return }
        if let e = error as NSError? {
            if e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled { return }
            if e.domain == "WebKitErrorDomain" && (e.code == 102 || e.code == 204) { return } // policy change / plug-in
            let failing = e.userInfo[NSURLErrorFailingURLErrorKey] as? URL
            NSLog("Musecube: provisional failure %@ %d %@", e.domain, e.code, failing?.absoluteString ?? "-")
            // Only a failure of the tool's own site gets the full error page; a failed hop to another
            // host (tracker, redirect, http link blocked by ATS) while a page is showing is ignored.
            let toolDomain = toolURLs[id].flatMap { domainKey(for: URL(string: $0)) }
            let sameSite = failing.map { u in
                guard let d = domainKey(for: u), let td = toolDomain else { return true }
                return d == td || d.hasSuffix("." + td) || td.hasSuffix("." + d)
            } ?? true
            if !sameSite && wv.url != nil { return }
            if !sameSite, wv.backForwardList.currentItem != nil { return }
            errors[id] = Self.describe(e)
            errorKinds[id] = Self.kind(e)
            if let u = failing, sameSite { failedURLs[id] = u }
        } else {
            errors.removeValue(forKey: id); errorKinds.removeValue(forKey: id)
            failedURLs.removeValue(forKey: id)
        }
        if id == currentToolID { loadError = errors[id]; loadErrorKind = errorKinds[id] }
    }

    static func kind(_ e: NSError) -> ErrorKind {
        guard e.domain == NSURLErrorDomain else { return .other }
        switch e.code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorDataNotAllowed,
             NSURLErrorTimedOut, NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed, NSURLErrorCannotConnectToHost,
             NSURLErrorSecureConnectionFailed, NSURLErrorInternationalRoamingOff:
            return .offline
        case NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateNotYetValid, NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorClientCertificateRejected, NSURLErrorClientCertificateRequired:
            return .certificate
        default: return .other
        }
    }

    /// Network came back (NWPathMonitor): reload the current tool if it is showing a network error.
    /// Other failed tools retry when the user switches to them (see load). Certificate errors never auto-retry.
    func networkDidReconnect() {
        func attempt() {
            guard let id = currentToolID, errorKinds[id] == .offline else { return }
            retry()
        }
        // The path can report "satisfied" a moment before DNS/routing settle; try now-ish and once more.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { attempt() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { attempt() }
    }

    static func describe(_ e: NSError) -> String {
        if e.domain == NSURLErrorDomain {
            switch e.code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorDataNotAllowed:
                return L("网络未连接，请检查网络后重试。")
            case NSURLErrorTimedOut:
                return L("网站响应超时，请稍后重试。")
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed, NSURLErrorCannotConnectToHost:
                return L("无法连接到这个网站，它可能暂时无法访问。")
            case NSURLErrorSecureConnectionFailed:
                // -1200 is usually a network/VPN/proxy or wake-from-sleep hiccup, not a bad certificate.
                return L("暂时无法建立安全连接，请稍后重试。")
            case NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate,
                 NSURLErrorServerCertificateNotYetValid, NSURLErrorServerCertificateHasUnknownRoot:
                return L("这个网站的安全证书有问题，已停止打开。")
            default: break
            }
        }
        return e.localizedDescription
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageEvent(.changed, webView)
        if picking { picking = false }
        applyCurrent()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        if url?.scheme?.lowercased() == "mailto" {
            decisionHandler(.cancel)
            if navigationAction.navigationType == .linkActivated, let u = url { NSWorkspace.shared.open(u) }
            return
        }
        guard Self.schemeAllowed(url) else { decisionHandler(.cancel); return }
        if navigationAction.targetFrame?.isMainFrame != false, Self.needsExternalBrowser(url) {
            decisionHandler(.cancel)
            handleGoogleSignIn(from: webView, blocked: url)
            return
        }
        if Self.isInsecure(url), let u = url {
            decisionHandler(.cancel)
            if navigationAction.targetFrame?.isMainFrame != false { warnInsecure(u) }
            return
        }
        // Top-level data: navigations are blocked by WebKit; save them instead.
        if navigationAction.targetFrame?.isMainFrame == true, !navigationAction.shouldPerformDownload,
           navigationAction.request.url?.scheme?.lowercased() == "data", let u = navigationAction.request.url {
            decisionHandler(.cancel)
            saveDataURL(u, from: webView)
            return
        }
        decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if !navigationResponse.canShowMIMEType { decisionHandler(.download); return }
        if let r = navigationResponse.response as? HTTPURLResponse,
           let cd = r.value(forHTTPHeaderField: "Content-Disposition"), cd.lowercased().contains("attachment") {
            decisionHandler(.download); return
        }
        // A tool navigating its main frame to a bare image/archive is almost always a "download" click.
        if navigationResponse.isForMainFrame, let mime = navigationResponse.response.mimeType?.lowercased(),
           mime.hasPrefix("image/") || mime == "application/zip" || mime == "application/octet-stream" {
            decisionHandler(.download); return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        track(download, from: webView)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        track(download, from: webView)
    }

    // MARK: - Downloads (handed to DownloadManager)

    /// Tool (name, home URL, its main web view) that owns a tool page or popup.
    private func toolInfo(for wv: WKWebView) -> (name: String, url: String?, main: WKWebView) {
        guard let id = owner[ObjectIdentifier(wv)] else { return (wv.url?.host ?? L("网页"), wv.url?.absoluteString, wv) }
        return (toolNames[id] ?? L("工具"), toolURLs[id], pool[id] ?? wv)
    }

    private func track(_ download: WKDownload, from wv: WKWebView) {
        let info = toolInfo(for: wv)
        DownloadManager.shared.attach(download, toolName: info.name, toolURL: info.url, webView: info.main)
        showToast(L("开始下载"))
        // Popup that only existed to start a download (cobalt style): close it if it shows nothing.
        if let win = popups.first(where: { $0.contentView === wv }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if wv.backForwardList.currentItem == nil || wv.url == nil || wv.url?.absoluteString == "about:blank" {
                    win.close()
                }
            }
        }
    }

    /// Decode a data: URL natively and save it.
    private func saveDataURL(_ url: URL, from wv: WKWebView, name: String? = nil) {
        let s = url.absoluteString
        guard let comma = s.firstIndex(of: ",") else { return }
        let header = String(s[s.index(s.startIndex, offsetBy: 5)..<comma])
        let payload = String(s[s.index(after: comma)...])
        let isB64 = header.lowercased().hasSuffix(";base64")
        let mime = header.split(separator: ";").first.map(String.init) ?? "text/plain"
        let data = isB64 ? Data(base64Encoded: payload.removingPercentEncoding ?? payload, options: .ignoreUnknownCharacters)
                         : (payload.removingPercentEncoding ?? payload).data(using: .utf8)
        guard let d = data else { showToast(L("下载失败：无法解析 data 链接")); return }
        let info = toolInfo(for: wv)
        DownloadManager.shared.saveGenerated(d, suggested: name, mime: mime.isEmpty ? "text/plain" : mime,
                                             sourceURL: "data:", toolName: info.name, toolURL: info.url)
    }

    private func handleDownloadMessage(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let wv = message.webView else { return }
        let info = toolInfo(for: wv)
        switch body["type"] as? String {
        case "blob-begin":
            guard let id = body["id"] as? String else { return }
            let mime = body["mime"] as? String
            let name = DownloadManager.sensibleName(body["name"] as? String, mime: mime, url: nil)
            let total = (body["size"] as? NSNumber)?.int64Value ?? 0
            let ext = (name as NSString).pathExtension.lowercased()
            let dm = DownloadManager.shared
            let allowed: Bool
            if DownloadManager.installerExtensions.contains(ext) {
                allowed = DownloadManager.confirmInstaller(name, tool: info.name)
            } else if dm.saveMode != .ask {
                allowed = DownloadManager.confirmGeneratedSave(name, tool: info.name)
            } else {
                allowed = true
            }
            let go = allowed && dm.openIncoming(token: id, name: name, toolName: info.name, toolURL: info.url, total: total)
            let fn = go ? "__wtbDLGo" : "__wtbDLAbort"
            wv.evaluateJavaScript("window.\(fn) && window.\(fn)(\(jsString(id)))", completionHandler: nil)
        case "blob-chunk":
            guard let id = body["id"] as? String, let b64 = body["data"] as? String else { return }
            DownloadManager.shared.appendIncoming(token: id, base64: b64)
        case "blob-end":
            guard let id = body["id"] as? String else { return }
            DownloadManager.shared.finishIncoming(id)
        case "data-url":
            guard let s = body["url"] as? String, let u = URL(string: s) else { return }
            saveDataURL(u, from: wv)
        case "blob":
            guard let b64 = body["data"] as? String, let d = Data(base64Encoded: b64) else { return }
            DownloadManager.shared.saveGenerated(d, suggested: body["name"] as? String, mime: body["mime"] as? String,
                                                 sourceURL: body["url"] as? String ?? "blob:",
                                                 toolName: info.name, toolURL: info.url)
        case "error":
            if let id = body["id"] as? String { DownloadManager.shared.abortIncoming(id, error: body["message"] as? String) }
            showToast(L("下载失败：") + (body["message"] as? String ?? ""))
        default: break
        }
    }

    // MARK: - UI delegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // target=_blank / window.open
        let scheme = navigationAction.request.url?.scheme?.lowercased()
        if let u = navigationAction.request.url, !Self.schemeAllowed(u) {
            if scheme == "mailto", navigationAction.navigationType == .linkActivated { NSWorkspace.shared.open(u) }
            return nil
        }
        if navigationAction.shouldPerformDownload || scheme == "blob" || scheme == "data" {
            // New window that is really a download (target=_blank download link, window.open(blob)).
            if scheme == "data", let u = navigationAction.request.url {
                saveDataURL(u, from: webView)
            } else {
                webView.startDownload(using: navigationAction.request) { [weak self] d in self?.track(d, from: webView) }
            }
            return nil
        }
        if Self.needsExternalBrowser(navigationAction.request.url) {
            handleGoogleSignIn(from: webView, blocked: navigationAction.request.url)
            return nil
        }
        if Self.isInsecure(navigationAction.request.url), let u = navigationAction.request.url {
            warnInsecure(u)
            return nil
        }
        // Real pop-up window that shares the opener's configuration, so window.opener /
        // postMessage based sign-ins (Apple, GitHub, Microsoft…) can complete.
        return makePopup(configuration: configuration, opener: webView, title: navigationAction.request.url?.host,
                         width: windowFeatures.width.map { CGFloat(truncating: $0) },
                         height: windowFeatures.height.map { CGFloat(truncating: $0) })
    }

    /// In-app pop-up window.
    @discardableResult
    func makePopup(configuration: WKWebViewConfiguration, opener: WKWebView?, title: String?,
                   width: CGFloat? = nil, height: CGFloat? = nil, load url: URL? = nil) -> WKWebView {
        let popup = AppWebView(frame: .zero, configuration: configuration)
        if let o = opener, let id = owner[ObjectIdentifier(o)] { owner[ObjectIdentifier(popup)] = id }
        popup.navigationDelegate = self
        popup.uiDelegate = self
        let vf = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1280, height: 800)
        let w = min(width ?? 520, vf.width - 40)
        let h = min(height ?? 680, vf.height - 40)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: max(w, 360), height: max(h, 360)),
                           styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.contentView = popup
        win.title = title ?? L("弹出窗口")
        win.center()
        win.makeKeyAndOrderFront(nil)
        popups.append(win)
        pageEvent(.opened, popup)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: win, queue: .main) { [weak self] _ in
            self?.popups.removeAll { $0 === win }
            self?.owner.removeValue(forKey: ObjectIdentifier(popup))
            self?.pageEvent(.closed, popup)
        }
        if let u = url { popup.load(URLRequest(url: u)) }
        return popup
    }


    func webViewDidClose(_ webView: WKWebView) {
        if let win = popups.first(where: { $0.contentView === webView }) { win.close() }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = parameters.allowsMultipleSelection
        p.canChooseDirectories = parameters.allowsDirectories
        p.canChooseFiles = true
        p.begin { r in completionHandler(r == .OK ? p.urls : nil) }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = NSAlert(); a.messageText = message; a.runModal(); completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = NSAlert(); a.messageText = message
        a.addButton(withTitle: L("确定")); a.addButton(withTitle: L("取消"))
        completionHandler(a.runModal() == .alertFirstButtonReturn)
    }
}
