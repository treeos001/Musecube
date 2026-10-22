import AppKit
import SwiftUI
import WebKit

struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}


struct ContentView: View {
    @ObservedObject var store: ToolStore
    @ObservedObject var web: WebController
    @ObservedObject var quick: QuickOpenState
    @ObservedObject private var net = NetworkMonitor.shared
    @State private var showAdd = false
    @State private var renaming: Tool?
    @State private var showStore = false
    @State private var findText = ""
    @AppStorage("sidebarHidden") private var sidebarHidden = false

    var body: some View {
        HStack(spacing: 0) {
            if !sidebarHidden {
                sidebar.frame(width: 64)
                Divider()
            }
            toolArea
        }
        .overlay(alignment: .top) {
            if quick.visible {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.08).contentShape(Rectangle()).onTapGesture { quick.hide() }
                    QuickOpenView(state: quick, store: store).padding(.top, 60)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 360)
        .onAppear { web.load(store.selected) }
        .onChange(of: store.selectedID) { _, id in
            if id != nil { showStore = false }
            quick.hide()
            web.load(store.selected)
        }
        .sheet(isPresented: $showAdd) { AddToolSheet(store: store, isPresented: $showAdd) }
        .sheet(item: $renaming) { t in RenameSheet(tool: t, store: store, renaming: $renaming) }
    }

    // MARK: Sidebar

    /// Selection highlight and the bottom Add square share this size (sidebar is 64pt wide).
    static let sidebarRow: CGFloat = 64    // = sidebar width: full-bleed square rows
    static let sidebarIcon: CGFloat = 42
    static let sidebarRadius: CGFloat = 10
    @State private var dragging: UUID?

    private var sidebar: some View {
        VStack(spacing: 0) {
            if !net.online {
                Text(L("离线"))
                    .font(.caption2.weight(.semibold)).foregroundColor(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.orange))
                    .padding(.top, 6)
                    .help(L("网络未连接。恢复后出错的工具会自动重新载入。"))
                    .accessibilityLabel(L("离线"))
            }
            // Own selection highlight (one square, nearly sidebar-wide) instead of the List's
            // default row highlight + icon tile, which stacked into box-in-box.
            // A List keeps a few points of row inset on macOS that listRowInsets can't remove,
            // so the column is a ScrollView: tiles are exactly sidebar width minus 4pt per side.
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                ForEach(store.visibleTools) { tool in
                    let selected = store.selectedID == tool.id
                    ToolIcon(image: store.icon(for: tool), name: tool.name, size: Self.sidebarIcon)
                        .frame(maxWidth: .infinity)
                        .frame(height: Self.sidebarRow)
                        .background(Rectangle().fill(selected ? Color.primary.opacity(0.10) : Color.clear))
                        .contentShape(Rectangle())
                        .onTapGesture { store.selectedID = tool.id }
                        .onDrag { dragging = tool.id; return NSItemProvider(object: tool.id.uuidString as NSString) }
                        .onDrop(of: [.text], delegate: SidebarDropDelegate(target: tool.id, store: store, dragging: $dragging))
                        .help(tool.name)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(tool.name)
                        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                        .accessibilityAction { store.selectedID = tool.id }
                        .contextMenu {
                            Button(L("重命名…")) { renaming = tool }
                            if FeatureFlags.simplifyEnabled {
                                Button(L("清除此网站的自定义精简规则")) {
                                    if let u = URL(string: tool.url), let d = domainKey(for: u) {
                                        web.rules.clear(d); web.applyCurrent()
                                    }
                                }
                            }
                            Button(web.isPinned(tool.id) ? L("取消常驻后台") : L("常驻后台（切走也不关闭）")) { web.togglePinned(tool.id) }
                            Button(L("隐藏")) { store.setHidden(tool.id, true) }
                            Divider()
                            Button(L("退出登录 / 清除此工具数据…")) { confirmClear(tool) }
                            Button(L("删除…")) { confirmDelete(tool) }
                        }
                }
                }
                .frame(maxWidth: .infinity)
                .onDrop(of: [.text], isTargeted: nil) { _ in dragging = nil; return true }
            }

            Divider()
            // U3: fixed below the list so it stays visible however many tools there are.
            Button { showAdd = true } label: {
                VStack(spacing: 2) {
                    Image(systemName: "plus").font(.system(size: 14, weight: .medium))
                    Text(L("添加")).font(.system(size: 10, weight: .medium)).lineLimit(1).minimumScaleFactor(0.7)
                }
                .frame(width: Self.sidebarIcon + 4, height: Self.sidebarIcon + 4)
                .overlay(RoundedRectangle(cornerRadius: Self.sidebarRadius).stroke(style: StrokeStyle(lineWidth: 1, dash: [3, 2.5])).padding(0.5))
                .contentShape(Rectangle())
            }
            .buttonStyle(SidebarButtonStyle())
            .padding(.top, 8)
            .help(L("添加工具（粘贴网址）"))
            .accessibilityLabel(L("添加"))
            Button {
                showStore = true
                store.selectedID = nil
            } label: {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(SidebarButtonStyle(active: showStore))
            .help(L("工具商店"))
            .accessibilityLabel(L("工具商店"))
            .padding(.top, 8)
            DownloadsButton()
            Button {
                NSApp.sendAction(#selector(AppDelegate.showAbout(_:)), to: nil, from: nil)
            } label: {
                Text(L("关于"))
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(SidebarButtonStyle())
            .help(L("关于 Musecube"))
            .accessibilityLabel(L("关于 Musecube"))
            .padding(.bottom, 8)
        }
    }

    // MARK: Tool area

    private var toolArea: some View {
        ZStack(alignment: .topTrailing) {
            if showStore {
                StoreView(store: store, catalog: catalog, open: { id in store.selectedID = id },
                          addURL: { showAdd = true }, delete: { confirmDelete($0) }, web: web)
            } else if store.visibleTools.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "square.grid.2x2").font(.system(size: 40)).foregroundColor(.secondary)
                    Text(L("还没有工具")).font(.title3)
                    HStack {
                        Button(L("打开工具商店")) { showStore = true }
                        Button(L("粘贴网址添加")) { showAdd = true }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    WebViewHost(webView: web.webView).id(ObjectIdentifier(web.webView))
                }
                if let err = web.loadError { errorPage(err) }
                if FeatureFlags.simplifyEnabled { controlBar.padding(8) }
                if web.findVisible { findBar.padding(8) }
            }
        }
        .overlay(alignment: .top) {
            if !showStore && web.isLoading && web.loadError == nil {
                GeometryReader { g in
                    Rectangle().fill(Color.accentColor)
                        .frame(width: g.size.width * max(0.05, web.progress), height: 2)
                        .animation(.easeOut(duration: 0.2), value: web.progress)
                }
                .frame(height: 2)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .bottom) { banners.padding(12) }
    }


    /// Native SwiftUI error page drawn over the web view (nothing is injected into the site).
    private func errorPage(_ message: String) -> some View {
        let kind = web.loadErrorKind
        let tool = store.selected
        let alts = tool.map { similarTools(to: $0) } ?? []
        return VStack(spacing: 12) {
            Image(systemName: kind == .certificate ? "lock.trianglebadge.exclamationmark"
                  : kind == .offline ? "wifi.exclamationmark" : "exclamationmark.triangle")
                .font(.system(size: 36)).foregroundColor(.secondary)
            Text(kind == .certificate ? L("证书有问题，已停止打开") : L("页面打不开")).font(.title3)
            Text(message).foregroundColor(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
            if kind == .offline && !net.online {
                Text(L("网络恢复后会自动重新载入。")).font(.caption).foregroundColor(.secondary)
            }
            HStack {
                Button(L("重试")) { web.retry() }.keyboardShortcut(.defaultAction)
                Button(L("在浏览器中打开")) {
                    if let t = tool, let u = URL(string: t.url) { NSWorkspace.shared.open(u) }
                }
                .disabled(tool.flatMap { URL(string: $0.url) } == nil)
                Menu(L("试试同类工具")) {
                    ForEach(alts, id: \.url) { c in
                        Button(c.displayName) { _ = store.add(urlString: c.url, name: c.displayName) }
                    }
                }
                .fixedSize()
                .disabled(alts.isEmpty)
                .help(alts.isEmpty ? L("这个工具不在内置目录里，没有同类推荐") : L("打开同分类的其他工具"))
                Button(L("报告这个工具有问题")) { if let t = tool { reportProblem(t, message) } }
                    .disabled(tool == nil)
                    .help(L("在 GitHub Issues 打开一份预填好的反馈，发送前可以修改或删除任何内容"))
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// Up to 3 catalog tools in the same category that are considered usable in the app.
    private func similarTools(to t: Tool) -> [CatalogTool] {
        let k = toolKey(t.url)
        guard let me = Catalog.shared.first(where: { toolKey($0.url) == k }), let cat = me.category else { return [] }
        var ok = Catalog.shared.filter { c in
            toolKey(c.url) != k && c.category == cat && c.tier != "backup"
                && c.google_only != true && !(c.webview_risk ?? "").hasPrefix("高")
                && !(c.note ?? "").contains("失效") && !(c.webview_risk ?? "").contains("失效")
        }
        return Array(ok.sorted { ($0.tier == "featured" ? 0 : 1) < ($1.tier == "featured" ? 0 : 1) }.prefix(3))
    }

    /// Opens a pre-filled email in the user's mail app. The app itself sends nothing.
    private func reportProblem(_ t: Tool, _ message: String) {
        let ver = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let subject = String(format: L("工具有问题：%@"), t.name)
        let body = String(format: L("App 版本：%@\n系统版本：macOS %@\n工具：%@\n\n问题描述："), ver, os, t.name) + message
        guard IssuesConfig.isConfigured, let base = URL(string: IssuesConfig.url) else { openIssues(); return }
        var c = URLComponents(url: base.appendingPathComponent("new"), resolvingAgainstBaseURL: false)
        c?.queryItems = [URLQueryItem(name: "title", value: subject), URLQueryItem(name: "body", value: body)]
        if let u = c?.url { NSWorkspace.shared.open(u) }
    }

    private var findBar: some View {
        HStack(spacing: 6) {
            TextField(L("在页面中查找"), text: $findText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .onSubmit { web.find(findText) }
                .onChange(of: findText) { _, t in web.find(t) }
            if web.findNoMatch && !findText.isEmpty { Text(L("无结果")).font(.caption).foregroundColor(.secondary) }
            Button { web.find(findText, backwards: true) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless).help(L("上一个")).accessibilityLabel(L("上一个匹配"))
            Button { web.find(findText) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless).help(L("下一个")).accessibilityLabel(L("下一个匹配"))
            Button { web.findVisible = false } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).keyboardShortcut(.cancelAction).help(L("关闭查找")).accessibilityLabel(L("关闭查找"))
        }
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
    }

    private var controlBar: some View {
        HStack(spacing: 6) {
            Picker("", selection: $web.simplified) {
                Text(L("精简")).tag(true)
                Text(L("原始")).tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 110)
            .help(L("在精简界面和原始网页之间切换"))

            Button(web.picking ? L("取消框选") : L("框选")) {
                if web.picking { web.stopPicking() } else { web.startPicking() }
            }
            .help(L("点选要保留的区域，按网站保存为精简规则"))
        }
        .padding(5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
    }

    private var catalog: [CatalogTool] { Catalog.shared }

    private func confirmClear(_ tool: Tool) {
        let a = NSAlert()
        a.messageText = String(format: L("退出“%@”的登录？"), tool.name)
        a.informativeText = L("将清除这个网站的 cookie 和登录状态，并重新载入。同一网站的其他工具会一起退出，其他网站不受影响。")
        a.alertStyle = .warning
        a.addButton(withTitle: L("清除"))
        a.addButton(withTitle: L("取消"))
        if a.runModal() == .alertFirstButtonReturn { web.clearData(for: tool) }
    }

    private func confirmDelete(_ tool: Tool) {
        let a = NSAlert()
        a.messageText = String(format: L("删除“%@”？"), tool.name)
        a.informativeText = L("该工具将从侧边栏移除，此操作无法撤销。")
        a.alertStyle = .warning
        a.addButton(withTitle: L("删除"))
        a.addButton(withTitle: L("取消"))
        if a.runModal() == .alertFirstButtonReturn { let shared = store.tools.contains { $0.id != tool.id && $0.storeID == tool.storeID }; if shared { web.forget(tool.id) } else { web.removeDataStore(for: tool) }; store.delete(tool.id) }
    }

    @ViewBuilder private var banners: some View {
        VStack(spacing: 8) {
            if !FeatureFlags.simplifyEnabled {
                EmptyView()
            } else if web.picking {
                Banner(text: L("框选模式：移动鼠标高亮区域，点击保留它；↑ 选上一级；Esc 取消"), color: .blue)
            } else if web.ruleMissing {
                Banner(text: L("精简规则没有匹配到内容（网站可能改版了），当前显示原始网页。"), color: .orange,
                       action: (L("重新框选"), { web.startPicking() }))
            } else if web.simplified && !web.hasRule && !store.tools.isEmpty {
                Banner(text: L("这个网站还没有精简规则，点右上角“框选”选择要保留的区域。"), color: .gray,
                       action: (L("框选"), { web.startPicking() }))
            }
            if let t = web.toast { Banner(text: t, color: .green) }
        }
    }
}

struct Banner: View {
    @Environment(\.colorSchemeContrast) private var contrast
    let text: String
    let color: Color
    var action: (String, () -> Void)? = nil
    var body: some View {
        HStack(spacing: 10) {
            Text(text).font(.callout)
            if let a = action { Button(a.0, action: a.1) }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(color.opacity(contrast == .increased ? 1 : 0.6), lineWidth: contrast == .increased ? 1.5 : 1))
        .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
    }
}

struct ToolIcon: View {
    let image: NSImage?
    let name: String
    var size: CGFloat = 30
    var body: some View {
        Group {
            if let img = image {
                Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 7).fill(Color.accentColor)
                    Text(String(name.prefix(1)).uppercased())
                        .font(.system(size: 15, weight: .bold)).foregroundColor(.white)
                }
            }
        }
        .frame(width: size, height: size)
        // Every icon gets the same rounded square, so white-tile favicons read as one shape.
        .clipShape(RoundedRectangle(cornerRadius: size * 10 / 42, style: .continuous))
    }
}

struct AddToolSheet: View {
    @ObservedObject var store: ToolStore
    @Binding var isPresented: Bool
    @State private var text = ""
    @State private var error = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("添加工具")).font(.headline)
            TextField(L("粘贴网址，例如 https://papago.naver.com/"), text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 360)
                .onSubmit(submit)
            if error { Text(L("网址无效")).font(.caption).foregroundColor(.red) }
            if text.lowercased().hasPrefix("http://"), let u = normalizeURL(text), u.scheme == "https" {
                Text(String(format: L("只支持 https，将自动改为：%@"), u.absoluteString)).font(.caption).foregroundColor(.orange)
            }
            HStack {
                Spacer()
                Button(L("取消")) { isPresented = false }.keyboardShortcut(.cancelAction)
                Button(L("添加"), action: submit).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .onAppear {
            if let s = NSPasteboard.general.string(forType: .string), normalizeURL(s) != nil,
               s.lowercased().hasPrefix("http") { text = s }
        }
    }

    private func submit() {
        if store.add(urlString: text) { isPresented = false } else { error = true }
    }
}

struct RenameSheet: View {
    let tool: Tool
    @ObservedObject var store: ToolStore
    @Binding var renaming: Tool?
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("重命名")).font(.headline)
            TextField(L("名称"), text: $name).textFieldStyle(.roundedBorder).frame(width: 300)
                .onSubmit(save)
            HStack {
                Spacer()
                Button(L("取消")) { renaming = nil }.keyboardShortcut(.cancelAction)
                Button(L("保存"), action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .onAppear { name = tool.name }
    }

    private func save() { store.rename(tool.id, to: name); renaming = nil }
}

/// One colour level for every sidebar button: secondary at rest, primary on hover or press,
/// accent when it represents the current view.
struct SidebarButtonStyle: ButtonStyle {
    var active = false
    func makeBody(configuration: Configuration) -> some View {
        SidebarButtonLabel(configuration: configuration, active: active)
    }
}

private struct SidebarButtonLabel: View {
    let configuration: ButtonStyle.Configuration
    let active: Bool
    @State private var hovering = false
    var body: some View {
        configuration.label
            .foregroundStyle(active ? AnyShapeStyle(Color.accentColor)
                             : (hovering || configuration.isPressed ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)))
            .onHover { hovering = $0 }
    }
}

/// Drag-to-reorder for the sidebar column (replaces List.onMove).
struct SidebarDropDelegate: DropDelegate {
    let target: UUID
    let store: ToolStore
    @Binding var dragging: UUID?
    func dropEntered(info: DropInfo) {
        guard let d = dragging, d != target,
              let from = store.visibleTools.firstIndex(where: { $0.id == d }),
              let to = store.visibleTools.firstIndex(where: { $0.id == target }) else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            store.moveVisible(from: IndexSet(integer: from), to: to > from ? to + 1 : to)
        }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
}
