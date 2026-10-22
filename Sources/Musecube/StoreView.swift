import AppKit
import SwiftUI
import WebKit

enum Catalog {
    static let shared: [CatalogTool] = CatalogTool.loadBundled()
}

struct StoreView: View {
    @ObservedObject var store: ToolStore
    let catalog: [CatalogTool]
    let open: (UUID) -> Void
    var addURL: () -> Void = {}
    var delete: (Tool) -> Void = { _ in }
    var web: WebController? = nil
    @State private var query = ""
    @State private var previewing: CatalogTool?
    /// Selected category chip; nil = 「全部」. Not persisted, so every launch starts at 「全部」.
    @State private var category: String?

    /// Catalog categories in first-appearance order.
    private var categories: [String] {
        var seen = Set<String>(); var out: [String] = []
        for t in catalog { let c = t.category ?? L("其他"); if seen.insert(c).inserted { out.append(c) } }
        return out
    }

    /// Sidebar tools (incl. hidden) whose domain matches no catalog entry.
    private var custom: [Tool] {
        let domains = Set(catalog.compactMap { domainKey(for: URL(string: $0.url)) })
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return store.tools.filter { t in
            guard let d = domainKey(for: URL(string: t.url)), !domains.contains(d) else { return false }
            return q.isEmpty || t.name.lowercased().contains(q) || t.url.lowercased().contains(q)
        }
    }

    private var filtered: [CatalogTool] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let base = category.map { c in catalog.filter { ($0.category ?? L("其他")) == c } } ?? catalog
        guard !q.isEmpty else { return base }
        return base.filter { t in
            ([t.name, t.name_en ?? "", t.url, t.category ?? "", t.description_zh ?? "", t.description_en ?? ""] + (t.tags ?? []))
                .contains { $0.lowercased().contains(q) }
        }
    }

    private var groups: [(String, [CatalogTool])] {
        var order: [String] = []
        var map: [String: [CatalogTool]] = [:]
        for t in filtered {
            let c = t.category ?? L("其他")
            if map[c] == nil { order.append(c) }
            map[c, default: []].append(t)
        }
        return order.map { ($0, map[$0]!) }
    }

    var body: some View {
        content.overlay {
            if let p = previewing, let w = web {
                StorePreview(item: p, store: store, web: w, open: open, close: { previewing = nil })
                    .background(Color(nsColor: .windowBackgroundColor))
            }
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("工具商店")).font(.title2.bold())
                Spacer()
                TextField(L("搜索工具、分类或标签"), text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
            }
            .padding(16)
            if !catalog.isEmpty { categoryChips }
            Divider()
            if catalog.isEmpty {
                Text(L("没有找到内置工具目录（tool_catalog.json）")).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        Text(L("我添加的")).font(.headline)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12)], spacing: 12) {
                            AddURLCard(action: addURL)
                            ForEach(custom) { t in CustomCard(tool: t, store: store, open: open, delete: delete) }
                        }
                        if custom.isEmpty && !query.trimmingCharacters(in: .whitespaces).isEmpty {
                            Text(L("没有匹配的自定义工具")).font(.callout).foregroundColor(.secondary)
                        }
                        Divider()
                        ForEach(groups, id: \.0) { g in
                            Text(L(g.0)).font(.headline)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12)], spacing: 12) {
                                ForEach(g.1) { t in StoreCard(item: t, store: store, open: open, preview: { previewing = $0 }, remove: delete) }
                            }
                        }
                        if filtered.isEmpty { Text(L("工具目录里没有匹配的工具")).foregroundColor(.secondary) }
                        Divider()
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(L("所列工具名称、图标与商标归各自所有者所有，与本产品无隶属、合作或背书关系。"))
                                .font(.caption2).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            Button(L("反馈")) { openIssues() }
                                .buttonStyle(.link).font(.caption2)
                        }
                    }
                    .padding(16)
                }
            }
        }
    }
}

extension StoreView {
    /// U1: category chips under the search field. Combines with the search query.
    var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                CategoryChip(title: L("全部"), selected: category == nil) { category = nil }
                ForEach(categories, id: \.self) { c in
                    CategoryChip(title: L(c), selected: category == c) { category = (category == c ? nil : c) }
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("按分类筛选"))
    }
}

struct CategoryChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: selected ? .semibold : .regular)).lineLimit(1).fixedSize()
                .padding(.horizontal, 10).padding(.vertical, 4)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(selected ? Color.accentColor : Color(nsColor: .controlBackgroundColor), in: Capsule())
                .overlay(Capsule().stroke(selected ? Color.clear : Color(nsColor: .separatorColor)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// U4: first card of 「我添加的」 — opens the existing add-URL sheet (same HTTPS-only path).
struct AddURLCard: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "plus").font(.system(size: 16, weight: .semibold)).frame(width: 32, height: 32)
                Text(L("粘贴任意 https 网页")).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(style: StrokeStyle(lineWidth: 1.25, dash: [4, 3])).foregroundStyle(.secondary))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L("粘贴任意 https 网页"))
    }
}

struct StoreCard: View {
    let item: CatalogTool
    @ObservedObject var store: ToolStore
    let open: (UUID) -> Void
    var preview: (CatalogTool) -> Void = { _ in }
    /// Existing sidebar delete flow (confirmation + site-data handling) from ContentView.
    var remove: (Tool) -> Void = { _ in }
    @ObservedObject private var icons = StoreIcons.shared
    /// U5: compact card; notes live in the hover help (fullText).
    static let height: CGFloat = 104

    private var fullText: String {
        [item.displayName, item.displayDescription, item.note, item.login_note].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ToolIcon(image: icons.image(for: item), name: item.displayName).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .center, spacing: 6) {
                    Text(item.displayName).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    storeStatus
                }
                if let d = item.displayDescription { Text(d).font(.callout).foregroundColor(.secondary).lineLimit(1) }
                HStack(spacing: 4) {
                    if item.requires_login == true { Badge(text: L("需登录"), color: .blue) }
                    if item.google_only == true { Badge(text: L("仅 Google 登录"), color: .red) }
                    if item.browser_recommended == true { Badge(text: L("建议在浏览器中使用"), color: .purple) }
                    if item.open_in_browser == true { Badge(text: L("badge.opensInBrowser"), color: .pink) }
                    if item.has_ads == true { Badge(text: L("有广告"), color: .orange) }
                }
                .lineLimit(1)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor)))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture(perform: openFromCard)
        .help(fullText)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(canOpenFromCard ? .isButton : [])
        .accessibilityHint(item.open_in_browser == true ? L("在浏览器中打开") : L("点按预览这个工具"))
    }

    private var addedTool: Tool? { store.tool(matching: item.url) }


    private var canOpenFromCard: Bool { true }

    private func openFromCard() {
        if item.open_in_browser == true {
            store.openCatalogInBrowser(item)
            return
        }
        preview(item)
    }


    @ViewBuilder private var storeStatus: some View {
        if item.open_in_browser == true {
            pill(L("在浏览器中打开"), plus: false, tone: .accentColor, fixedWidth: false,
                 help: L("在浏览器中打开"), hint: "") { store.openCatalogInBrowser(item) }
        } else if let t = addedTool {
            pill(L("store.remove"), plus: false, tone: .secondary, fixedWidth: true,
                 help: L("从侧边栏移除"), hint: L("从侧边栏移除")) { remove(t) }
        } else {
            pill(L("添加"), plus: true, tone: .accentColor, fixedWidth: true,
                 help: L("添加到侧边栏"), hint: L("添加到侧边栏")) {
                let sel = store.selectedID
                store.add(urlString: item.url, name: item.displayName, open: false)
                store.selectedID = sel
            }
        }
    }

    /// Add / Remove share one fixed size so the card never jumps (zh or en); open-in-browser keeps its width.
    static let pillSize = CGSize(width: 76, height: 26)

    private func pill(_ title: String, plus: Bool, tone: Color, fixedWidth: Bool,
                      help: String, hint: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if plus { Image(systemName: "plus").font(.system(size: 10, weight: .bold)) }
                Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(tone)
            .padding(.horizontal, fixedWidth ? 0 : 12)
            .frame(width: fixedWidth ? Self.pillSize.width : nil, height: Self.pillSize.height)
            .background(tone == .secondary ? Color.gray.opacity(0.16) : tone.opacity(0.12), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(help)
        .accessibilityLabel(title)
        .accessibilityHint(hint)
    }
}

/// Icon buttons on a store card / preview header: add, or (when added) open + hide/show.
struct StoreActions: View {
    let item: CatalogTool
    @ObservedObject var store: ToolStore
    let open: (UUID) -> Void
    var body: some View {
        HStack(spacing: 2) {
            if let t = store.tool(matching: item.url) {
                if !t.hidden {
                    iconButton("arrow.up.forward.app", L("打开")) { open(t.id) }
                }
                iconButton(t.hidden ? "eye" : "eye.slash", t.hidden ? L("在侧边栏显示") : L("从侧边栏隐藏")) { store.setHidden(t.id, !t.hidden) }
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    .frame(width: 24, height: 24)
                    .help(L("已添加")).accessibilityLabel(L("已添加"))
            } else if item.open_in_browser == true {
                iconButton("safari", L("在浏览器中打开")) { store.openCatalogInBrowser(item) }
            } else {
                iconButton("plus.circle", L("添加到侧边栏")) {
                    let sel = store.selectedID
                    store.add(urlString: item.url, name: item.displayName, open: false)
                    store.selectedID = sel // stay in the store
                }
            }
        }
        .font(.system(size: 15))
    }
    private func iconButton(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 24, height: 24).contentShape(Rectangle()) }
            .buttonStyle(.borderless).help(label).accessibilityLabel(label)
    }
}

/// In-store preview of a tool's page. Added tools use their own login store; others use a
/// throw-away (non-persistent) store, so previewing never leaves data behind.
struct StorePreview: View {
    let item: CatalogTool
    @ObservedObject var store: ToolStore
    let web: WebController
    let open: (UUID) -> Void
    let close: () -> Void
    @State private var webView: WKWebView?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).frame(width: 26, height: 26).contentShape(Rectangle()) }
                    .buttonStyle(.borderless).keyboardShortcut(.cancelAction)
                    .help(L("关闭预览（Esc）")).accessibilityLabel(L("关闭预览"))
                ToolIcon(image: StoreIcons.shared.image(for: item), name: item.displayName).scaleEffect(0.8).accessibilityHidden(true)
                Text(item.displayName).font(.headline).lineLimit(1)
                if item.open_in_browser == true { Badge(text: L("badge.opensInBrowser"), color: .pink) }
                if let d = item.displayDescription { Text(d).font(.caption).foregroundColor(.secondary).lineLimit(1) }
                Spacer()
                StoreActions(item: item, store: store, open: { id in close(); open(id) })
                if let u = URL(string: item.url) {
                    Button { NSWorkspace.shared.open(u) } label: { Image(systemName: "safari").frame(width: 24, height: 24) }
                        .buttonStyle(.borderless).help(L("在浏览器中打开")).accessibilityLabel(L("在浏览器中打开"))
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.bar)
            Divider()
            if item.open_in_browser == true {
                // Not loaded in the app (not even as a preview).
                VStack(spacing: 10) {
                    Image(systemName: "safari").font(.system(size: 32)).foregroundStyle(.secondary)
                    Text(L("这个工具会在默认浏览器中打开，App 内不加载。")).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if let d = item.displayDescription { Text(d).font(.callout).multilineTextAlignment(.center).frame(maxWidth: 420) }
                    Button(L("在浏览器中打开")) { store.openCatalogInBrowser(item) }.controlSize(.large)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
            } else if let wv = webView { WebViewHost(webView: wv) } else { Color(nsColor: .windowBackgroundColor) }
            if let n = item.trademark_note?.trimmingCharacters(in: .whitespaces), !n.isEmpty {
                Divider()
                Text(n).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 4)
            }
        }
        .onAppear {
            guard item.open_in_browser != true, let u = normalizeURL(item.url) else { return }
            webView = web.makePreviewWebView(url: u, storeID: store.siteStoreID(for: item.url))
        }
        .onDisappear { webView?.stopLoading(); webView = nil }
    }
}

struct Badge: View {
    let text: String
    let color: Color
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        let hi = contrast == .increased
        Text(text).font(.caption2.weight(hi ? .semibold : .medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(hi ? 0.28 : 0.15), in: Capsule())
            .overlay(Capsule().stroke(color.opacity(hi ? 0.9 : 0), lineWidth: 1))
            .foregroundColor(hi ? .primary : color)
    }
}

struct CustomCard: View {
    let tool: Tool
    @ObservedObject var store: ToolStore
    let open: (UUID) -> Void
    let delete: (Tool) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ToolIcon(image: store.icon(for: tool), name: tool.name)
            VStack(alignment: .leading, spacing: 6) {
                Text(tool.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text(tool.url).font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    if !tool.hidden { Button(L("打开")) { open(tool.id) }.controlSize(.small) }
                    Button(tool.hidden ? L("显示") : L("隐藏")) { store.setHidden(tool.id, !tool.hidden) }.controlSize(.small)
                    Button(L("删除")) { delete(tool) }.controlSize(.small)
                    if tool.hidden { Badge(text: L("已隐藏"), color: .gray) }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 90, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor)))
    }
}
