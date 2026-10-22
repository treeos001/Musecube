import AppKit
import SwiftUI

/// Quick Open (⌥M / ⌘K): local fuzzy search over added tools and the bundled catalog.
/// Pure in-memory matching: no network requests, search terms are never stored.
final class QuickOpenState: ObservableObject {
    @Published var visible = false
    @Published var query = ""
    func show() { query = ""; visible = true }
    func hide() { visible = false; query = "" }
}

enum QuickOpenItem: Identifiable {
    case tool(Tool)
    case catalog(CatalogTool)
    var id: String {
        switch self { case .tool(let t): return "t:" + t.id.uuidString; case .catalog(let c): return "c:" + c.url }
    }
}

enum QuickOpenMatcher {
    /// Score of `q` against `s` (both lowercased): prefix > word start > substring > subsequence; nil = no match.
    static func score(_ q: String, _ s: String) -> Int? {
        guard !q.isEmpty, !s.isEmpty else { return nil }
        if s == q { return 1000 }
        if s.hasPrefix(q) { return 800 }
        if let r = s.range(of: q) {
            let before = s[..<r.lowerBound].last
            let wordStart = before.map { !$0.isLetter && !$0.isNumber } ?? true
            return wordStart ? 600 : 400
        }
        // Subsequence ("jwio" → "jwt.io"); only for ASCII-ish queries of 2+ chars to avoid noise.
        guard q.count >= 2 else { return nil }
        var it = s.makeIterator()
        var gaps = 0
        for ch in q {
            var found = false
            while let c = it.next() { if c == ch { found = true; break }; gaps += 1 }
            if !found { return nil }
        }
        return max(1, 200 - gaps)
    }

    static func fields(name: String, catalog c: CatalogTool?, url: String) -> [(String, Int)] {
        // (text, weight bonus): names count most, then category/tags, then the host.
        var f: [(String, Int)] = [(name, 300)]
        if let c = c {
            f.append((c.name, 300))
            if let n = c.name_en { f.append((n, 300)) }
            if let cat = c.category { f.append((cat, 150)) }
            for t in c.tags ?? [] { f.append((t, 150)) }
        }
        if let h = URL(string: url)?.host { f.append((h.replacingOccurrences(of: "www.", with: ""), 100)) }
        return f
    }

    static func best(_ q: String, _ fields: [(String, Int)]) -> Int? {
        var best: Int?
        for (text, bonus) in fields {
            if let s = score(q, text.lowercased()) { best = max(best ?? 0, s + bonus) }
        }
        return best
    }

    static func search(_ raw: String, tools: [Tool], catalog: [CatalogTool]) -> (added: [Tool], store: [CatalogTool]) {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let byKey = Dictionary(catalog.map { (toolKey($0.url), $0) }, uniquingKeysWith: { a, _ in a })
        if q.isEmpty { return (Array(tools.filter { !$0.hidden }.prefix(9)), []) }
        // Multiple words must all match (any field).
        let words = q.split(separator: " ").map(String.init)
        func total(_ f: [(String, Int)]) -> Int? {
            var sum = 0
            for w in words { guard let s = best(w, f) else { return nil }; sum += s }
            return sum
        }
        var added: [(Tool, Int)] = []
        var addedKeys = Set<String>()
        for t in tools {
            let k = toolKey(t.url); addedKeys.insert(k)
            if let s = total(fields(name: t.name, catalog: byKey[k], url: t.url)) { added.append((t, s)) }
        }
        var store: [(CatalogTool, Int)] = []
        for c in catalog where !addedKeys.contains(toolKey(c.url)) {
            if let s = total(fields(name: c.displayName, catalog: c, url: c.url)) { store.append((c, s)) }
        }
        return (added.sorted { $0.1 > $1.1 }.prefix(12).map(\.0), store.sorted { $0.1 > $1.1 }.prefix(8).map(\.0))
    }
}

struct QuickOpenView: View {
    @ObservedObject var state: QuickOpenState
    @ObservedObject var store: ToolStore
    @State private var selection = 0
    @FocusState private var focused: Bool

    private var results: (added: [Tool], store: [CatalogTool]) {
        QuickOpenMatcher.search(state.query, tools: store.tools, catalog: Catalog.shared)
    }
    private var items: [QuickOpenItem] { results.added.map { .tool($0) } + results.store.map { .catalog($0) } }

    var body: some View {
        let r = results
        let all = items
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField(L("搜索工具、分类或标签…"), text: $state.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18))
                    .focused($focused)
                    .onSubmit { activate(all) }
                    .onKeyPress(.downArrow) { move(1, all.count); return .handled }
                    .onKeyPress(.upArrow) { move(-1, all.count); return .handled }
                    .onKeyPress(.escape) { state.hide(); return .handled }
                    .accessibilityLabel(L("快速打开"))
            }
            .padding(12)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        if all.isEmpty {
                            Text(L("没有匹配的工具")).foregroundColor(.secondary).padding(12)
                        }
                        if !r.added.isEmpty { header(L("已添加")) }
                        ForEach(Array(r.added.enumerated()), id: \.element.id) { i, t in
                            row(index: i, icon: AnyView(ToolIcon(image: store.icon(for: t), name: t.name).scaleEffect(0.8)),
                                title: t.name, subtitle: subtitle(for: t.url), badge: nil, items: all)
                        }
                        if !r.store.isEmpty { header(L("商店里还没添加的工具")) }
                        ForEach(Array(r.store.enumerated()), id: \.element.id) { j, c in
                            row(index: r.added.count + j,
                                icon: AnyView(ToolIcon(image: StoreIcons.shared.cachedImage(for: c.url), name: c.displayName).scaleEffect(0.8)),
                                title: c.displayName, subtitle: c.category ?? "", badge: L("回车添加"), items: all)
                        }
                    }
                    .padding(6)
                }
                .onChange(of: selection) { _, s in withAnimation(nil) { proxy.scrollTo(s) } }
            }
            .frame(maxHeight: 340)
        }
        .frame(width: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
        .onAppear { selection = 0; DispatchQueue.main.async { focused = true } }
        .onChange(of: state.query) { _, _ in selection = 0 }
        .onChange(of: state.visible) { _, v in if v { selection = 0; DispatchQueue.main.async { focused = true } } }
    }

    private func subtitle(for url: String) -> String {
        if let c = Catalog.shared.first(where: { toolKey($0.url) == toolKey(url) }), let cat = c.category { return cat }
        return URL(string: url)?.host ?? ""
    }

    private func header(_ s: String) -> some View {
        Text(s).font(.caption).foregroundColor(.secondary).padding(.horizontal, 8).padding(.top, 6)
    }

    private func row(index: Int, icon: AnyView, title: String, subtitle: String, badge: String?, items: [QuickOpenItem]) -> some View {
        HStack(spacing: 10) {
            icon.frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1)
                if !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundColor(.secondary).lineLimit(1) }
            }
            Spacer()
            if let b = badge { Text(b).font(.caption).foregroundColor(.secondary) }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(index == selection ? Color.accentColor.opacity(0.25) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { selection = index; activate(items) }
        .id(index)
    }

    private func move(_ d: Int, _ n: Int) {
        guard n > 0 else { return }
        selection = (selection + d + n) % n
    }

    private func activate(_ all: [QuickOpenItem]) {
        guard selection < all.count else { return }
        switch all[selection] {
        case .tool(let t):
            if t.hidden { store.setHidden(t.id, false) }
            store.selectedID = t.id
        case .catalog(let c):
            if !store.openCatalogInBrowser(c) { _ = store.add(urlString: c.url, name: c.displayName) } // else: adds to the sidebar and selects it
        }
        state.hide()
    }
}
