import AppKit
import Foundation

struct Tool: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var url: String
    var iconFile: String?
    /// Identifier of this tool's own persistent WKWebsiteDataStore (cookies, localStorage…).
    var storeID: UUID = UUID()
    /// Hidden tools stay in tools.json but are not shown in the sidebar.
    var hidden: Bool = false

    init(id: UUID = UUID(), name: String, url: String, iconFile: String? = nil) {
        self.id = id; self.name = name; self.url = url; self.iconFile = iconFile
    }

    enum CodingKeys: String, CodingKey { case id, name, url, iconFile, storeID, hidden }

    /// Backward compatible: older tools.json entries have no storeID / hidden.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        url = try c.decode(String.self, forKey: .url)
        iconFile = try c.decodeIfPresent(String.self, forKey: .iconFile)
        storeID = try c.decodeIfPresent(UUID.self, forKey: .storeID) ?? UUID()
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
    }
}

/// Real home folder (inside the App Sandbox, NSHomeDirectory() points into the container).
let realHome: URL = {
    if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
        return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
    }
    return FileManager.default.homeDirectoryForCurrentUser
}()

/// One-time copy from a pre-release WebToolbox data folder into Musecube's folder.
/// A sandboxed build cannot read that folder. This only succeeds for an unsandboxed run.
enum Migration {
    static func run() {
        let fm = FileManager.default
        let new = Paths.support
        let marker = new.appendingPathComponent(".migrated")
        guard !fm.fileExists(atPath: marker.path) else { return }
        defer { fm.createFile(atPath: marker.path, contents: Data()) }
        guard !fm.fileExists(atPath: Paths.tools.path) else { return }
        let sources = [
            realHome.appendingPathComponent("Library/Application Support/WebToolbox", isDirectory: true),
        ]
        guard let old = sources.first(where: { fm.fileExists(atPath: $0.appendingPathComponent("tools.json").path) }),
              old.standardizedFileURL.path != new.standardizedFileURL.path else { return }
        for f in ["tools.json", "rules.json"] {
            let src = old.appendingPathComponent(f)
            if fm.fileExists(atPath: src.path) { try? fm.copyItem(at: src, to: new.appendingPathComponent(f)) }
        }
        let oldIcons = old.appendingPathComponent("icons", isDirectory: true)
        for f in (try? fm.contentsOfDirectory(atPath: oldIcons.path)) ?? [] {
            try? fm.copyItem(at: oldIcons.appendingPathComponent(f), to: Paths.icon(f))
        }
        NSLog("Musecube: migrated data from %@", old.path)
    }
}

/// An entry of the bundled tool catalog (tool_catalog.json).
struct CatalogTool: Decodable, Identifiable {
    var name: String
    var url: String
    var category: String?
    var description_zh: String?
    var tags: [String]?
    var requires_login: Bool?
    var has_ads: Bool?
    var login_methods: [String]?
    var login_note: String?
    var google_only: Bool?
    var browser_recommended: Bool?
    var google_login_fallback: String?
    var has_official_mac_app: Bool?
    var native_client_url: String?
    var note: String?
    /// Official icon URL on the tool's own site (verified by research). Fetched at runtime, never bundled.
    var icon_url: String?
    /// Open this tool in the system default browser instead of inside the app (optional; missing = false).
    var open_in_browser: Bool?
    /// Short trademark/ownership note shown in small print on the store detail page (optional).
    var trademark_note: String?
    /// Timer/metronome tools: keep their page running at full speed while the window is hidden.
    var keeps_running_in_background: Bool?
    var tier: String?
    var webview_risk: String?
    var name_en: String?
    var description_en: String?

    /// English fields when the UI language is English and they exist; otherwise Chinese.
    /// English unless the system language is Chinese. A missing preference falls back to English.
    static var preferEnglish: Bool { !(Bundle.main.preferredLocalizations.first ?? "en").hasPrefix("zh") }
    var displayName: String {
        if Self.preferEnglish, let n = name_en?.trimmingCharacters(in: .whitespaces), !n.isEmpty { return n }
        return name
    }
    var displayDescription: String? {
        if Self.preferEnglish, let d = description_en?.trimmingCharacters(in: .whitespaces), !d.isEmpty { return d }
        return description_zh
    }

    /// Badge + download link only when the catalog explicitly says there is an official Mac app.
    var hasNativeClient: Bool { has_official_mac_app == true }
    var nativeURL: URL? {
        guard hasNativeClient, let s = native_client_url?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        return URL(string: s)
    }
    var id: String { url }

    static func loadBundled() -> [CatalogTool] {
        guard let u = Bundle.main.url(forResource: "tool_catalog", withExtension: "json"),
              let d = try? Data(contentsOf: u) else { return [] }
        do { return try JSONDecoder().decode([CatalogTool].self, from: d) }
        catch { NSLog("Musecube: catalog decode failed: %@", "\(error)"); return [] }
    }
}

/// Key used to match a catalog entry with a sidebar tool: host (no www) + path without trailing "/".
/// Catalog flag lookup; custom (non-catalog) tools default to false.
func keepsRunningInBackground(_ url: String) -> Bool {
    let k = toolKey(url)
    return Catalog.shared.first(where: { toolKey($0.url) == k })?.keeps_running_in_background == true
}

func toolKey(_ s: String) -> String {
    guard let u = URL(string: s), let d = domainKey(for: u) else { return s.lowercased() }
    var p = u.path
    while p.hasSuffix("/") { p.removeLast() }
    return d + p.lowercased()
}

func isLocalHost(_ h: String?) -> Bool {
    guard let h = h?.lowercased() else { return false }
    return h == "localhost" || h == "127.0.0.1" || h == "::1" || h.hasSuffix(".localhost")
}

enum Paths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Musecube", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("icons", isDirectory: true),
                                                 withIntermediateDirectories: true)
        return dir
    }()
    static var tools: URL { support.appendingPathComponent("tools.json") }
    static var rules: URL { support.appendingPathComponent("rules.json") }
    static func icon(_ name: String) -> URL {
        support.appendingPathComponent("icons", isDirectory: true).appendingPathComponent(name)
    }
}

/// Domain key used for rules: lowercased host without leading "www.".
func domainKey(for url: URL?) -> String? {
    guard var h = url?.host?.lowercased(), !h.isEmpty else { return nil }
    if h.hasPrefix("www.") { h.removeFirst(4) }
    return h
}

func normalizeURL(_ raw: String) -> URL? {
    var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !s.isEmpty else { return nil }
    if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") { s = "https://" + s }
    guard var u = URL(string: s), let h = u.host, h.contains(".") || h == "localhost" else { return nil }
    // HTTPS only: upgrade http:// (except local development hosts).
    if u.scheme?.lowercased() == "http", !isLocalHost(h),
       var c = URLComponents(url: u, resolvingAgainstBaseURL: false) {
        c.scheme = "https"
        if c.port == 80 { c.port = nil }
        if let up = c.url { u = up }
    }
    return u
}

final class ToolStore: ObservableObject {
    @Published var tools: [Tool] = [] { didSet { save() } }
    @Published var selectedID: UUID? { didSet { if let id = selectedID { noteRecent(id) } } }

    /// Catalog used for per-tool flags (injectable for tests).
    var catalog: [CatalogTool] = Catalog.shared
    /// How external opens happen (injectable for tests so no browser is launched).
    var browserOpener: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// Only explicit catalog entries flagged open_in_browser go to the default browser.
    /// Tools in the user's sidebar (including URLs they added themselves) always open in the app.
    @discardableResult
    func openCatalogInBrowser(_ c: CatalogTool) -> Bool {
        guard c.open_in_browser == true, let u = normalizeURL(c.url) else { return false }
        browserOpener(u)
        return true
    }
    private var persist = true

    /// In-memory store for tests: no files, no migration.
    init(testTools: [Tool], catalog: [CatalogTool]) {
        persist = false
        self.catalog = catalog
        tools = testTools
    }

    /// Most recently opened tools (newest first), kept locally only for the menu bar "Recent Tools" menu.
    var recentTools: [Tool] {
        let ids = (UserDefaults.standard.stringArray(forKey: "recentToolIDs") ?? []).compactMap(UUID.init(uuidString:))
        return ids.compactMap { id in tools.first { $0.id == id && !$0.hidden } }.prefix(5).map { $0 }
    }
    private func noteRecent(_ id: UUID) {
        var a = UserDefaults.standard.stringArray(forKey: "recentToolIDs") ?? []
        a.removeAll { $0 == id.uuidString }; a.insert(id.uuidString, at: 0)
        UserDefaults.standard.set(Array(a.prefix(20)), forKey: "recentToolIDs")
    }
    private var loading = false

    init() {
        Migration.run()
        loading = true
        var needsSave = false
        if let d = try? Data(contentsOf: Paths.tools),
           let t = try? JSONDecoder().decode([Tool].self, from: d) {
            tools = t
            // Old entries got a freshly generated storeID / hidden; persist them.
            if let raw = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]],
               raw.contains(where: { $0["storeID"] == nil || $0["hidden"] == nil }) { needsSave = true }
        }
        // One-time merge: entries of the same site (domainKey) share one data store.
        // Keep the store of the entry that comes first in tools.json (no add date is recorded;
        // new entries are appended, so first ≈ earliest unless the user reordered the sidebar).
        // Superseded stores are NOT deleted from disk, so this can be undone if needed.
        if !UserDefaults.standard.bool(forKey: "storeMerge.v1") {
            var keep: [String: UUID] = [:]
            var orphans: [String] = []
            for i in tools.indices {
                guard let d = domainKey(for: URL(string: tools[i].url)) else { continue }
                if let sid = keep[d] {
                    if tools[i].storeID != sid { orphans.append(tools[i].storeID.uuidString); tools[i].storeID = sid; needsSave = true }
                } else { keep[d] = tools[i].storeID }
            }
            if !orphans.isEmpty {
                UserDefaults.standard.set(orphans, forKey: "storeMerge.v1.orphans")
                NSLog("Musecube: merged %d per-tool data stores into per-site stores", orphans.count)
            }
            UserDefaults.standard.set(true, forKey: "storeMerge.v1")
        }
        loading = false
        if needsSave { save() }
        selectedID = visibleTools.first?.id
    }

    var selected: Tool? { tools.first { $0.id == selectedID } }
    var visibleTools: [Tool] { tools.filter { !$0.hidden } }

    func tool(matching url: String) -> Tool? {
        let k = toolKey(url)
        return tools.first { toolKey($0.url) == k }
    }

    /// Data store shared by every entry of the same site (domainKey); nil if no entry of that site exists.
    func siteStoreID(for url: String) -> UUID? {
        if let t = tool(matching: url) { return t.storeID }
        guard let d = domainKey(for: URL(string: url)) else { return nil }
        return tools.first { domainKey(for: URL(string: $0.url)) == d }?.storeID
    }

    func setHidden(_ id: UUID, _ hidden: Bool) {
        guard let i = tools.firstIndex(where: { $0.id == id }) else { return }
        tools[i].hidden = hidden
        if hidden, selectedID == id { selectedID = visibleTools.first?.id }
    }

    /// Reorder within the visible sidebar list; hidden tools keep their entries at the end.
    func moveVisible(from: IndexSet, to: Int) {
        var vis = visibleTools
        vis.move(fromOffsets: from, toOffset: to)
        tools = vis + tools.filter { $0.hidden }
    }

    private func save() {
        guard !loading, persist else { return }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted]
        if let d = try? enc.encode(tools) { try? d.write(to: Paths.tools, options: .atomic) }
    }

    @discardableResult
    func add(urlString: String, name: String? = nil, open: Bool = true) -> Bool {
        guard var url = normalizeURL(urlString) else { return false } // also upgrades http → https
        var name = name
        // Match by host (no www) + path, so different tools on one domain (e.g. iLovePDF features) can coexist.
        let k = toolKey(url.absoluteString)
        if let existing = tools.first(where: { toolKey($0.url) == k }) {
            if existing.hidden { setHidden(existing.id, false) }
            if open { selectedID = existing.id }
            return true
        }
        if let c = Catalog.shared.first(where: { toolKey($0.url) == k }), let cu = normalizeURL(c.url) {
            url = cu
            name = c.displayName
        }
        let fixedName = name
        var tool = Tool(id: UUID(), name: name ?? url.host ?? url.absoluteString, url: url.absoluteString, iconFile: nil)
        // Features split from the same site (e.g. iLovePDF compress / merge) share one login store.
        if let d = domainKey(for: url), let sib = tools.first(where: { domainKey(for: URL(string: $0.url)) == d }) {
            tool.storeID = sib.storeID
        }
        if let png = StoreIcons.shared.cachedPNG(for: url.absoluteString) {
            let file = "\(tool.id.uuidString).png"
            if (try? png.write(to: Paths.icon(file), options: .atomic)) != nil { tool.iconFile = file }
        }
        tools.append(tool)
        if open { selectedID = tool.id }
        SiteMeta.fetch(url) { [weak self] title, iconData in
            guard let self = self, let idx = self.tools.firstIndex(where: { $0.id == tool.id }) else { return }
            var t = self.tools[idx]
            if fixedName == nil, let title = title, !title.isEmpty { t.name = title }
            if let data = iconData, t.iconFile == nil {
                let file = "\(tool.id.uuidString).png"
                try? data.write(to: Paths.icon(file), options: .atomic)
                self.iconCache.removeObject(forKey: file as NSString)
                t.iconFile = file
            }
            self.tools[idx] = t
        }
        return true
    }

    func rename(_ id: UUID, to name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, let i = tools.firstIndex(where: { $0.id == id }) else { return }
        tools[i].name = n
    }

    func delete(_ id: UUID) {
        guard let i = tools.firstIndex(where: { $0.id == id }) else { return }
        if let f = tools[i].iconFile { iconCache.removeObject(forKey: f as NSString); try? FileManager.default.removeItem(at: Paths.icon(f)) }
        tools.remove(at: i)
        if selectedID == id { selectedID = visibleTools.first?.id }
    }

    func move(from: IndexSet, to: Int) { tools.move(fromOffsets: from, toOffset: to) }

    /// In-memory icon cache: the sidebar re-renders on every page-load progress tick,
    /// so reading PNGs from disk each time wasted I/O and CPU.
    private let iconCache = NSCache<NSString, NSImage>()

    func icon(for tool: Tool) -> NSImage? {
        guard let f = tool.iconFile else { return nil }
        if let img = iconCache.object(forKey: f as NSString) { return img }
        guard let img = NSImage(contentsOf: Paths.icon(f)) else { return nil }
        iconCache.setObject(img, forKey: f as NSString)
        return img
    }
}

/// Fetches page title and favicon (as PNG data). Completion called on main queue.
enum SiteMeta {
    /// Honest app identifier (no browser impersonation). Appended to WebKit's default UA in web views.
    static let appUA: String = {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        return "Musecube/\(v)"
    }()

    static func get(_ url: URL, _ done: @escaping (Data?) -> Void) {
        let req = URLRequest(url: url, timeoutInterval: 15)
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) { done(nil); return }
            done(data)
        }.resume()
    }

    static func fetch(_ url: URL, completion: @escaping (String?, Data?) -> Void) {
        get(url) { data in
            let html = data.flatMap { String(data: $0, encoding: .utf8) ?? String(data: $0, encoding: .isoLatin1) } ?? ""
            let title = parseTitle(html)
            iconCandidates(html, base: url) { candidates in
                tryIcons(candidates) { png in
                    DispatchQueue.main.async { completion(title, png) }
                }
            }
        }
    }

    /// Only the site's own icons (no third-party favicon services): apple-touch-icon,
    /// web manifest icons (largest first), <link rel=icon>, then /favicon.ico.
    static func iconCandidates(_ html: String, base: URL, _ done: @escaping ([URL]) -> Void) {
        var (touch, normal) = parseIcons(html, base: base)
        if let host = base.host, let scheme = base.scheme,
           let u = URL(string: "\(scheme)://\(host)/favicon.ico") { normal.append(u) }
        guard let m = manifestURL(html, base: base) else { done(touch + normal); return }
        get(m) { data in
            var mf: [URL] = []
            if let d = data, let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let icons = obj["icons"] as? [[String: Any]] {
                let sized = icons.compactMap { i -> (Int, URL)? in
                    guard let src = i["src"] as? String, let u = URL(string: src, relativeTo: m)?.absoluteURL else { return nil }
                    let sz = (i["sizes"] as? String)?.split(separator: " ").compactMap { Int($0.split(separator: "x").first ?? "") }.max() ?? 0
                    return (sz, u)
                }
                mf = sized.sorted { $0.0 > $1.0 }.map { $0.1 }
            }
            done(touch + mf + normal)
        }
    }

    /// Fetches the first usable icon among candidates, as 128x128 PNG data. Completion on a background queue.
    static func fetchIcon(pageURL: URL, preferred: URL?, _ done: @escaping (Data?) -> Void) {
        let viaPage = {
            get(pageURL) { data in
                let html = data.flatMap { String(data: $0, encoding: .utf8) ?? String(data: $0, encoding: .isoLatin1) } ?? ""
                iconCandidates(html, base: pageURL) { tryIcons($0, done) }
            }
        }
        if let p = preferred {
            tryIcons([p]) { png in if let png = png { done(png) } else { viaPage() } }
        } else { viaPage() }
    }

    private static func manifestURL(_ html: String, base: URL) -> URL? {
        guard let re = try? NSRegularExpression(pattern: "<link\\b[^>]*>", options: [.caseInsensitive]) else { return nil }
        let ns = html as NSString
        for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: m.range)
            if attr("rel", tag)?.lowercased() == "manifest", let h = attr("href", tag),
               let u = URL(string: decodeEntities(h), relativeTo: base)?.absoluteURL, u.scheme == "https" { return u }
        }
        return nil
    }

    private static func tryIcons(_ list: [URL], _ done: @escaping (Data?) -> Void) {
        guard let first = list.first else { done(nil); return }
        get(first) { data in
            if let d = data, let png = pngThumbnail(d) { done(png) } else { tryIcons(Array(list.dropFirst()), done) }
        }
    }

    /// Decodes any image NSImage understands (PNG/ICO/JPEG/SVG) and redraws it at 128x128.
    static func pngThumbnail(_ d: Data, side: Int = 128) -> Data? {
        guard let img = NSImage(data: d), img.isValid, img.size.width > 0, img.size.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high
        let s = CGFloat(side), r = min(s / img.size.width, s / img.size.height)
        let w = img.size.width * r, h = img.size.height * r
        img.draw(in: NSRect(x: (s - w) / 2, y: (s - h) / 2, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    static func parseTitle(_ html: String) -> String? {
        guard let r = html.range(of: "<title[^>]*>([\\s\\S]*?)</title>", options: [.regularExpression, .caseInsensitive]) else { return nil }
        var s = String(html[r])
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        s = decodeEntities(s).trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return s.isEmpty ? nil : String(s.prefix(40))
    }

    static func decodeEntities(_ s: String) -> String {
        var r = s
        for (k, v) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " ")] {
            r = r.replacingOccurrences(of: k, with: v)
        }
        return r
    }

    /// Returns icon URLs from <link rel=...icon...>, apple-touch-icon first, skipping SVG.
    static func parseIcons(_ html: String, base: URL) -> ([URL], [URL]) {
        guard let re = try? NSRegularExpression(pattern: "<link\\b[^>]*>", options: [.caseInsensitive]) else { return ([], []) }
        let ns = html as NSString
        var touch: [(Int, URL)] = [], normal: [(Int, URL)] = []
        for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: m.range)
            guard let rel = attr("rel", tag)?.lowercased(), rel.contains("icon"),
                  let href = attr("href", tag),
                  let u = URL(string: decodeEntities(href), relativeTo: base)?.absoluteURL else { continue }
            let sz = attr("sizes", tag)?.split(separator: " ").compactMap { Int($0.lowercased().split(separator: "x").first ?? "") }.max()
                ?? (u.path.lowercased().hasSuffix(".svg") ? 512 : 0)
            if rel.contains("apple-touch") { touch.append((sz, u)) } else { normal.append((sz, u)) }
        }
        // Largest declared size first within each group.
        func order(_ a: [(Int, URL)]) -> [URL] { a.enumerated().sorted { ($0.1.0, -$0.0) > ($1.1.0, -$1.0) }.map { $0.1.1 } }
        return (order(touch), order(normal))
    }

    private static func attr(_ name: String, _ tag: String) -> String? {
        let pattern = "\\b\(name)\\s*=\\s*(\"([^\"]*)\"|'([^']*)'|([^\\s>]+))"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = tag as NSString
        guard let m = re.firstMatch(in: tag, range: NSRange(location: 0, length: ns.length)) else { return nil }
        for i in 2...4 where m.range(at: i).location != NSNotFound { return ns.substring(with: m.range(at: i)) }
        return nil
    }
}

/// Simplification rules per domain. User rules override built-in presets.
/// Rule syntax: CSS selector candidates separated by "||" (first that matches wins);
/// a candidate "A && B" means the lowest common ancestor of A and B.
final class RuleStore {
    static let presets: [String: String] = [
        // Checked against public HTML on 2026-10-16 (SSR snapshot; still confirm in WKWebView on Mac).
        // Papago: old #sourceEditArea/#txtSource are gone; data-testid is stable across CSS-module hashes.
        "papago.naver.com": "[data-testid=\"source-editor\"] && [data-testid=\"target-editor\"] || [data-testid=\"source-editor\"] || main",
        // TinyPNG: drop zone + result list are siblings; LCA keeps both. #upload-dropbox-zone alone is too narrow.
        "tinypng.com": "#upload-dropbox-zone && .upload__output-container || section.upload-container || #upload-dropbox-zone || main",
    ]

    private(set) var user: [String: String] = [:]

    init() {
        if let d = try? Data(contentsOf: Paths.rules),
           let r = try? JSONDecoder().decode([String: String].self, from: d) { user = r }
    }

    func rule(for domain: String?) -> String? {
        guard let d = domain else { return nil }
        return user[d] ?? Self.presets[d]
    }

    func hasUserRule(_ domain: String?) -> Bool { domain.map { user[$0] != nil } ?? false }

    func set(_ selector: String, for domain: String) { user[domain] = selector; save() }
    func clear(_ domain: String) { user[domain] = nil; save() }

    private func save() {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(user) { try? d.write(to: Paths.rules, options: .atomic) }
    }
}
