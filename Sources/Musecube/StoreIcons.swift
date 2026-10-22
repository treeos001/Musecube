import AppKit
import Foundation

/// Store-card icons, fetched at runtime from each tool's own site (never bundled, no third-party favicon service).
/// Order: catalog icon_url → page parsing (apple-touch-icon / manifest / rel icon / favicon.ico) → placeholder.
/// Cached on disk (Caches/StoreIcons) and in memory; at most 4 concurrent fetches, 15 s timeout per request.
final class StoreIcons: ObservableObject {
    static let shared = StoreIcons()

    @Published private(set) var version = 0
    private let memory = NSCache<NSString, NSImage>()
    private var inflight = Set<String>()
    private var failed = Set<String>()          // per launch only; retried next launch
    private let gate = DispatchSemaphore(value: 4)
    private let queue = DispatchQueue(label: "webtoolbox.storeicons", attributes: .concurrent)

    private let dir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("StoreIcons", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    static func key(_ url: String) -> String {
        String(toolKey(url).map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" })
    }
    private func file(_ url: String) -> URL { dir.appendingPathComponent(Self.key(url) + ".png") }

    func cachedPNG(for url: String) -> Data? { try? Data(contentsOf: file(url)) }

    /// Cached icon only; never starts a network fetch (Quick Open must stay offline).
    func cachedImage(for url: String) -> NSImage? {
        let k = Self.key(url) as NSString
        if let img = memory.object(forKey: k) { return img }
        if let img = NSImage(contentsOf: file(url)) { memory.setObject(img, forKey: k); return img }
        return nil
    }

    /// Returns the icon if available; otherwise starts a background fetch (UI refreshes via `version`).
    func image(for item: CatalogTool) -> NSImage? {
        let k = Self.key(item.url) as NSString
        if let img = memory.object(forKey: k) { return img }
        if let img = NSImage(contentsOf: file(item.url)) { memory.setObject(img, forKey: k); return img }
        load(item)
        return nil
    }

    private func load(_ item: CatalogTool) {
        let k = Self.key(item.url)
        guard !inflight.contains(k), !failed.contains(k), let page = URL(string: item.url) else { return }
        inflight.insert(k)
        let preferred = item.icon_url.flatMap { $0.isEmpty ? nil : URL(string: $0) }.flatMap { $0.scheme == "https" ? $0 : nil }
        let dest = file(item.url)
        queue.async { [weak self] in
            guard let self = self else { return }
            self.gate.wait()
            SiteMeta.fetchIcon(pageURL: page, preferred: preferred) { png in
                self.gate.signal()
                if let png = png { try? png.write(to: dest, options: .atomic) }
                DispatchQueue.main.async {
                    self.inflight.remove(k)
                    if let png = png, let img = NSImage(data: png) {
                        self.memory.setObject(img, forKey: k as NSString)
                        self.version += 1
                    } else { self.failed.insert(k) }
                }
            }
        }
    }
}
