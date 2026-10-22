import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications
import WebKit

struct DownloadRecord: Codable, Identifiable, Equatable {
    enum State: String, Codable { case downloading, finished, failed, cancelled }
    var id = UUID()
    var filename: String
    var toolName: String
    var toolURL: String?
    var sourceURL: String?
    var destPath: String?
    var bytes: Int64 = 0
    var total: Int64 = -1
    var state: State = .downloading
    var error: String?
    var date = Date()

    var progress: Double { total > 0 ? min(1, Double(bytes) / Double(total)) : 0 }
    var destURL: URL? { destPath.map { URL(fileURLWithPath: $0) } }
    /// Page-generated content (blob:/data:) can't be re-requested.
    var isPageGenerated: Bool {
        guard let s = sourceURL?.lowercased() else { return true }
        return s.hasPrefix("blob:") || s.hasPrefix("data:")
    }
}

/// Tracks every download, persists history, picks destinations and posts notifications.
final class DownloadManager: NSObject, ObservableObject, WKDownloadDelegate {
    static let shared = DownloadManager()

    @Published private(set) var records: [DownloadRecord] = []
    @Published private(set) var unseen = 0 { didSet { updateBadge() } }

    enum SaveMode: String, CaseIterable { case downloads, folder, ask }
    @Published var saveMode: SaveMode {
        didSet { UserDefaults.standard.set(saveMode.rawValue, forKey: "dlMode") }
    }
    @Published private(set) var customFolder: URL?

    /// Fallback web view for retries when the original one is gone (set by WebController).
    var fallbackWebView: () -> WKWebView? = { nil }

    private final class IncomingFile {
        let recordID: UUID
        let file: URL
        let handle: FileHandle
        var bytes: Int64 = 0
        init(recordID: UUID, file: URL, handle: FileHandle) {
            self.recordID = recordID
            self.file = file
            self.handle = handle
        }
    }
    private var incoming: [String: IncomingFile] = [:]
    private var live: [UUID: WKDownload] = [:]
    private var byDownload: [ObjectIdentifier: UUID] = [:]
    private var observers: [UUID: NSKeyValueObservation] = [:]
    private var resumeData: [UUID: Data] = [:]
    private var webViews: [UUID: WeakBox] = [:]
    private var lastProgressSave = Date.distantPast

    final class WeakBox { weak var wv: WKWebView?; init(_ w: WKWebView?) { wv = w } }

    private static var file: URL { Paths.support.appendingPathComponent("downloads.json") }

    override init() {
        saveMode = SaveMode(rawValue: UserDefaults.standard.string(forKey: "dlMode") ?? "") ?? .downloads
        super.init()
        if let d = try? Data(contentsOf: Self.file),
           let r = try? JSONDecoder().decode([DownloadRecord].self, from: d) {
            // Anything still "downloading" was interrupted by quitting the app.
            records = r.map { var x = $0; if x.state == .downloading { x.state = .failed; x.error = L("App 退出导致下载中断") }; return x }
        }
        resolveBookmark()
    }

    var active: [DownloadRecord] { records.filter { $0.state == .downloading } }
    var activeProgress: Double {
        let a = active
        guard !a.isEmpty else { return 0 }
        return a.map(\.progress).reduce(0, +) / Double(a.count)
    }

    // MARK: Settings

    private var accessing: URL?
    private func resolveBookmark() {
        guard let data = UserDefaults.standard.data(forKey: "dlBookmark") else { return }
        var stale = false
        guard let u = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil,
                               bookmarkDataIsStale: &stale) else { return }
        accessing?.stopAccessingSecurityScopedResource()
        if u.startAccessingSecurityScopedResource() { accessing = u }
        customFolder = u
        if stale, let nd = try? u.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(nd, forKey: "dlBookmark")
        }
    }

    func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        p.prompt = L("选择"); p.message = L("选择下载文件的保存位置")
        guard p.runModal() == .OK, let u = p.url,
              let data = try? u.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        else { return }
        UserDefaults.standard.set(data, forKey: "dlBookmark")
        resolveBookmark()
        saveMode = .folder
    }

    static var defaultDir: URL {
        #if DEBUG
        if let i = CommandLine.arguments.firstIndex(of: "--wtb-debug-dldir"), i + 1 < CommandLine.arguments.count {
            let u = URL(fileURLWithPath: CommandLine.arguments[i + 1], isDirectory: true)
            try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
            return u
        }
        #endif
        return realHome.appendingPathComponent("Downloads", isDirectory: true)
    }

    var saveDir: URL { saveMode == .folder ? (customFolder ?? Self.defaultDir) : Self.defaultDir }

    /// Unique destination (auto-rename "name (1).ext") or a save panel when "每次询问".
    /// Automatic destinations stay inside the save directory.
    func chooseDestination(for name: String, _ done: @escaping (URL?) -> Void) {
        if saveMode == .ask {
            let p = NSSavePanel()
            p.nameFieldStringValue = name
            p.directoryURL = Self.defaultDir
            p.begin { r in
                guard r == .OK, let u = p.url else { done(nil); return }
                try? FileManager.default.removeItem(at: u) // user already confirmed replacing
                done(u)
            }
            return
        }
        let dir = saveDir.standardizedFileURL
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var n = 1
        var dest = Self.fileInside(dir, name)
        while let d = dest, FileManager.default.fileExists(atPath: d.path) {
            let candidate = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            n += 1
            dest = Self.fileInside(dir, candidate)
        }
        done(dest)
    }

    /// A single path component inside `dir`. Rejects `.`, `..`, and any name that resolves outside `dir`.
    static func fileInside(_ dir: URL, _ name: String) -> URL? {
        guard name != ".", name != "..", !name.isEmpty else { return nil }
        let dest = dir.appendingPathComponent(name).standardizedFileURL
        let base = dir.standardizedFileURL.path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard dest.path.hasPrefix(prefix) else { return nil }
        return dest
    }

    /// download attribute / Content-Disposition name, else URL name, plus an extension from the MIME type.
    static func sensibleName(_ suggested: String?, mime: String?, url: URL?) -> String {
        var name = (suggested ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // WebKit names nameless blobs "Unknown" / "Unknown.png": use "download" instead.
        if (name as NSString).deletingPathExtension.lowercased() == "unknown" {
            let ext = (name as NSString).pathExtension
            name = ext.isEmpty ? "" : "download." + ext
        }
        if name.isEmpty {
            let last = url?.lastPathComponent ?? ""
            let scheme = url?.scheme?.lowercased() ?? ""
            name = (scheme == "blob" || scheme == "data" || last.isEmpty || last == "/") ? "download" : last
        }
        name = (name as NSString).lastPathComponent
        name = name.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
        name = name.components(separatedBy: .controlCharacters).joined()
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name == "." || name == ".." || name.isEmpty { name = "download" }
        if name.count > 180 {
            let ext = (name as NSString).pathExtension
            let base = (name as NSString).deletingPathExtension
            let room = max(1, 180 - (ext.isEmpty ? 0 : ext.count + 1))
            let cut = String(base.prefix(room))
            name = ext.isEmpty ? cut : cut + "." + ext
        }
        if (name as NSString).pathExtension.isEmpty, let m = mime?.split(separator: ";").first.map(String.init),
           let ext = UTType(mimeType: m.trimmingCharacters(in: .whitespaces))?.preferredFilenameExtension {
            name += "." + ext
        }
        return name
    }

    // MARK: Tracking WKDownloads

    func attach(_ download: WKDownload, toolName: String, toolURL: String?, webView: WKWebView?, reuse: UUID? = nil) {
        download.delegate = self
        let src = download.originalRequest?.url?.absoluteString
        let id: UUID
        if let r = reuse, let i = records.firstIndex(where: { $0.id == r }) {
            id = r
            records[i].state = .downloading; records[i].error = nil; records[i].bytes = 0; records[i].date = Date()
        } else {
            let rec = DownloadRecord(filename: Self.sensibleName(nil, mime: nil, url: download.originalRequest?.url),
                                     toolName: toolName, toolURL: toolURL, sourceURL: src)
            id = rec.id
            records.insert(rec, at: 0)
        }
        live[id] = download
        byDownload[ObjectIdentifier(download)] = id
        webViews[id] = WeakBox(webView)
        observers[id] = download.progress.observe(\.fractionCompleted) { [weak self] p, _ in
            let done = p.completedUnitCount, total = p.totalUnitCount
            DispatchQueue.main.async { self?.update(id) { $0.bytes = done; if total > 0 { $0.total = total } } }
        }
        save()
    }

    private func update(_ id: UUID, _ f: (inout DownloadRecord) -> Void) {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        f(&records[i])
    }

    private func id(of d: WKDownload) -> UUID? { byDownload[ObjectIdentifier(d)] }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let name = Self.sensibleName(suggestedFilename, mime: response.mimeType, url: response.url ?? download.originalRequest?.url)
        let id = id(of: download)
        let tool = id.flatMap { i in records.first { $0.id == i }?.toolName } ?? ""
        guard Self.confirmInstaller(name, tool: tool) else {
            if let id = id { update(id) { $0.filename = name; $0.state = .cancelled }; save() }
            completionHandler(nil); return
        }
        chooseDestination(for: name) { [weak self] url in
            if let id = id {
                self?.update(id) {
                    $0.filename = url?.lastPathComponent ?? name
                    $0.destPath = url?.path
                    if response.expectedContentLength > 0 { $0.total = response.expectedContentLength }
                    if url == nil { $0.state = .cancelled }
                }
                self?.save()
            }
            completionHandler(url)
        }
    }

    /// Installer / executable types that get a one-time confirmation before downloading.
    /// .zip is intentionally not included: very common tool output; quarantine still propagates on unzip.
    static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "app", "command", "sh"]

    /// Ask before downloading an installer/executable. Default button = Cancel. Returns true to download.
    static func confirmInstaller(_ filename: String, tool: String) -> Bool {
        guard installerExtensions.contains((filename as NSString).pathExtension.lowercased()) else { return true }
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = String(format: L("「%@」想下载安装文件 %@，确定要下载吗？"), tool.isEmpty ? "Musecube" : tool, filename)
        let cancel = a.addButton(withTitle: L("取消"))
        let ok = a.addButton(withTitle: L("下载"))
        cancel.keyEquivalent = "\r"; ok.keyEquivalent = ""
        return a.runModal() == .alertSecondButtonReturn
    }

    /// Page-generated save with no save panel. The default button downloads to this Mac.
    static func confirmGeneratedSave(_ filename: String, tool: String) -> Bool {
        let a = NSAlert()
        a.alertStyle = .informational
        a.messageText = String(format: L("「%@」想把 %@ 下载到这台 Mac"), tool.isEmpty ? "Musecube" : tool, filename)
        a.informativeText = L("文件会保存到你设置的下载位置，并带上隔离标记。")
        a.addButton(withTitle: L("下载到本地"))
        a.addButton(withTitle: L("取消"))
        return a.runModal() == .alertFirstButtonReturn
    }

    /// Make sure a downloaded file carries com.apple.quarantine (LSFileQuarantineEnabled normally does this
    /// for sandboxed apps; this is the fallback). Never opens the file.
    static func ensureQuarantine(_ url: URL, source: URL?) {
        let ns = url as NSURL
        var existing: AnyObject?
        try? ns.getResourceValue(&existing, forKey: .quarantinePropertiesKey)
        if existing != nil { return }
        var props: [String: Any] = [kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
                                    kLSQuarantineAgentNameKey as String: "Musecube"]
        if let s = source { props[kLSQuarantineDataURLKey as String] = s }
        do { try ns.setResourceValue(props, forKey: .quarantinePropertiesKey) }
        catch {
            // Last resort: raw xattr in the standard "flags;time;agent;uuid" format.
            let v = String(format: "0083;%08x;Musecube;", Int(Date().timeIntervalSince1970))
            let r = v.withCString { setxattr(url.path, "com.apple.quarantine", $0, strlen($0), 0, 0) }
            if r != 0 { NSLog("Musecube: could not set quarantine on %@", url.path) }
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let id = id(of: download) else { return }
        if let p = records.first(where: { $0.id == id })?.destPath { Self.ensureQuarantine(URL(fileURLWithPath: p), source: download.originalRequest?.url) }
        update(id) { r in
            r.state = .finished
            if let p = r.destPath, let s = (try? FileManager.default.attributesOfItem(atPath: p))?[.size] as? Int64 {
                r.bytes = s; r.total = s
            }
        }
        cleanup(id, download)
        resumeData[id] = nil
        finished(id)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData data: Data?) {
        guard let id = id(of: download) else { return }
        let cancelled = (error as NSError).code == NSURLErrorCancelled
        update(id) { r in
            if r.state != .cancelled { r.state = cancelled ? .cancelled : .failed }
            if !cancelled { r.error = error.localizedDescription }
        }
        if let data = data { resumeData[id] = data }
        cleanup(id, download)
        save()
    }

    private func cleanup(_ id: UUID, _ d: WKDownload) {
        live[id] = nil
        observers[id] = nil
        byDownload[ObjectIdentifier(d)] = nil
    }

    // MARK: Page-generated files written in pieces

    /// Opens a temporary file for a blob the page will send in chunks. Returns false if the file cannot be created.
    func openIncoming(token: String, name: String, toolName: String, toolURL: String?, total: Int64) -> Bool {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        guard FileManager.default.createFile(atPath: file.path, contents: nil),
              let handle = FileHandle(forWritingAtPath: file.path) else { return false }
        var rec = DownloadRecord(filename: name, toolName: toolName, toolURL: toolURL, sourceURL: "blob:")
        rec.total = total
        records.insert(rec, at: 0)
        incoming[token] = IncomingFile(recordID: rec.id, file: file, handle: handle)
        save()
        return true
    }

    func appendIncoming(token: String, base64: String) {
        guard let slot = incoming[token], let data = Data(base64Encoded: base64) else { return }
        do {
            try slot.handle.write(contentsOf: data)
            slot.bytes += Int64(data.count)
            update(slot.recordID) { $0.bytes = slot.bytes }
        } catch {
            abortIncoming(token, error: error.localizedDescription)
        }
    }

    func finishIncoming(_ token: String) {
        guard let slot = incoming.removeValue(forKey: token) else { return }
        try? slot.handle.close()
        let name = records.first { $0.id == slot.recordID }?.filename ?? "download"
        chooseDestination(for: name) { [weak self] url in
            guard let self else { return }
            guard let url else {
                try? FileManager.default.removeItem(at: slot.file)
                self.update(slot.recordID) { $0.state = .cancelled }
                self.save()
                return
            }
            do {
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                try FileManager.default.moveItem(at: slot.file, to: url)
                Self.ensureQuarantine(url, source: nil)
                self.update(slot.recordID) { r in
                    r.state = .finished
                    r.destPath = url.path
                    r.filename = url.lastPathComponent
                    r.bytes = slot.bytes
                    r.total = slot.bytes
                }
                self.finished(slot.recordID)
            } catch {
                try? FileManager.default.removeItem(at: slot.file)
                self.update(slot.recordID) { $0.state = .failed; $0.error = error.localizedDescription }
                self.save()
            }
        }
    }

    func abortIncoming(_ token: String, error: String? = nil) {
        guard let slot = incoming.removeValue(forKey: token) else { return }
        try? slot.handle.close()
        try? FileManager.default.removeItem(at: slot.file)
        update(slot.recordID) { r in
            r.state = error == nil ? .cancelled : .failed
            r.error = error
        }
        save()
    }

    // MARK: Page-generated data (data: URLs, or one complete blob)

    func saveGenerated(_ data: Data, suggested: String?, mime: String?, sourceURL: String?, toolName: String, toolURL: String?) {
        let name = Self.sensibleName(suggested, mime: mime, url: sourceURL.flatMap { URL(string: $0) })
        var rec = DownloadRecord(filename: name, toolName: toolName, toolURL: toolURL, sourceURL: sourceURL)
        rec.total = Int64(data.count)
        let ext = (name as NSString).pathExtension.lowercased()
        if Self.installerExtensions.contains(ext) {
            guard Self.confirmInstaller(name, tool: toolName) else { return }
        } else if saveMode != .ask {
            guard Self.confirmGeneratedSave(name, tool: toolName) else { return }
        }
        records.insert(rec, at: 0)
        chooseDestination(for: name) { [weak self] url in
            guard let self = self else { return }
            guard let url = url else { self.update(rec.id) { $0.state = .cancelled }; self.save(); return }
            do {
                try data.write(to: url, options: .atomic)
                Self.ensureQuarantine(url, source: sourceURL.flatMap { URL(string: $0) })
                self.update(rec.id) { $0.state = .finished; $0.destPath = url.path; $0.filename = url.lastPathComponent; $0.bytes = Int64(data.count) }
                self.finished(rec.id)
            } catch {
                self.update(rec.id) { $0.state = .failed; $0.error = error.localizedDescription }
                self.save()
            }
        }
    }

    // MARK: Actions

    func cancel(_ id: UUID) {
        if let token = incoming.first(where: { $0.value.recordID == id })?.key { abortIncoming(token) }
        update(id) { $0.state = .cancelled }
        guard let d = live[id] else { save(); return }
        d.cancel { [weak self] data in
            DispatchQueue.main.async {
                if let data = data { self?.resumeData[id] = data }
                self?.cleanup(id, d)
                self?.save()
            }
        }
    }

    func canRetry(_ r: DownloadRecord) -> Bool {
        (r.state == .failed || r.state == .cancelled) && (resumeData[r.id] != nil || !r.isPageGenerated)
    }

    func retry(_ id: UUID) {
        guard let r = records.first(where: { $0.id == id }),
              let wv = webViews[id]?.wv ?? fallbackWebView() else { return }
        if let rd = resumeData.removeValue(forKey: id) {
            if let p = r.destPath { try? FileManager.default.removeItem(atPath: p) }
            wv.resumeDownload(fromResumeData: rd) { [weak self] d in
                self?.attach(d, toolName: r.toolName, toolURL: r.toolURL, webView: wv, reuse: id)
            }
        } else if let s = r.sourceURL, let u = URL(string: s), !r.isPageGenerated {
            wv.startDownload(using: URLRequest(url: u)) { [weak self] d in
                self?.attach(d, toolName: r.toolName, toolURL: r.toolURL, webView: wv, reuse: id)
            }
        }
    }

    func openInBrowser(_ r: DownloadRecord) {
        let s = r.isPageGenerated ? r.toolURL : r.sourceURL
        if let s = s, let u = URL(string: s) { NSWorkspace.shared.open(u) }
    }

    func reveal(_ r: DownloadRecord) {
        if let u = r.destURL { NSWorkspace.shared.activateFileViewerSelecting([u]) }
    }

    func open(_ r: DownloadRecord) {
        if let u = r.destURL { NSWorkspace.shared.open(u) }
    }

    func fileExists(_ r: DownloadRecord) -> Bool { r.destPath.map { FileManager.default.fileExists(atPath: $0) } ?? false }

    /// Clears the list only; files on disk are never touched. Running downloads stay.
    func clearHistory() {
        records.removeAll { $0.state != .downloading }
        resumeData = resumeData.filter { k, _ in records.contains { $0.id == k } }
        save()
    }

    func markSeen() { unseen = 0 }

    // MARK: Finish → badge + notification

    private func finished(_ id: UUID) {
        save()
        unseen += 1
        guard let r = records.first(where: { $0.id == id }) else { return }
        notify(r)
    }

    private func updateBadge() { NSApp.dockTile.badgeLabel = unseen > 0 ? "\(unseen)" : nil }

    private var askedNotify = false
    private func notify(_ r: DownloadRecord) {
        guard Bundle.main.bundleIdentifier != nil else { return } // UNUserNotificationCenter needs a bundle
        let c = UNUserNotificationCenter.current()
        let post = {
            let content = UNMutableNotificationContent()
            content.title = L("下载完成")
            content.body = String(format: L("%@（来自 %@）"), r.filename, r.toolName)
            c.add(UNNotificationRequest(identifier: r.id.uuidString, content: content, trigger: nil))
        }
        if askedNotify { post(); return }
        askedNotify = true
        c.requestAuthorization(options: [.alert, .sound]) { ok, _ in if ok { post() } }
    }

    // MARK: Persistence

    private func save() {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted]; enc.dateEncodingStrategy = .iso8601
        if let d = try? enc.encode(records) { try? d.write(to: Self.file, options: .atomic) }
    }
}

// MARK: - UI

struct DownloadsButton: View {
    @ObservedObject var dm = DownloadManager.shared
    @State private var open = false

    var body: some View {
        Button { open.toggle(); dm.markSeen() } label: {
            ZStack {
                if !dm.active.isEmpty {
                    Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 2.5).frame(width: 26, height: 26)
                    Circle().trim(from: 0, to: max(0.03, dm.activeProgress))
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90)).frame(width: 26, height: 26)
                }
                Image(systemName: "arrow.down.circle").font(.system(size: 16, weight: .medium))
                if dm.unseen > 0 {
                    Text("\(dm.unseen)").font(.system(size: 9, weight: .bold)).foregroundColor(.white)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().fill(Color.red)).offset(x: 11, y: -11)
                }
            }
            .frame(width: 36, height: 36).contentShape(Rectangle())
        }
        .buttonStyle(SidebarButtonStyle())
        .help(L("下载")).accessibilityLabel(L("下载"))
        .popover(isPresented: $open, arrowEdge: .trailing) { DownloadsPanel() }
    }
}

struct DownloadsPanel: View {
    @ObservedObject var dm = DownloadManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L("下载")).font(.headline)
                Spacer()
                Button(L("清除记录")) { dm.clearHistory() }
                    .disabled(dm.records.allSatisfy { $0.state == .downloading })
                    .help(L("只清除列表，不会删除已下载的文件"))
            }
            .padding(12)
            Divider()
            if dm.records.isEmpty {
                Text(L("还没有下载")).foregroundColor(.secondary).frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(dm.records) { r in DownloadRow(r: r); Divider() }
                    }
                }
                .frame(height: min(CGFloat(dm.records.count) * 64, 360))
            }
            Divider()
            settings.padding(12)
        }
        .frame(width: 420)
        .onAppear { dm.markSeen() }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(L("保存到"), selection: $dm.saveMode) {
                Text(L("下载文件夹")).tag(DownloadManager.SaveMode.downloads)
                Text(dm.customFolder?.lastPathComponent ?? L("其他文件夹…")).tag(DownloadManager.SaveMode.folder)
                Text(L("每次询问")).tag(DownloadManager.SaveMode.ask)
            }
            .onChange(of: dm.saveMode) { _, m in
                if m == .folder && dm.customFolder == nil { dm.chooseFolder(); if dm.customFolder == nil { dm.saveMode = .downloads } }
            }
            HStack {
                Text(dm.saveMode == .ask ? L("每次下载时选择位置") : dm.saveDir.path)
                    .font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button(L("选择文件夹…")) { dm.chooseFolder() }.controlSize(.small)
            }
        }
    }
}

struct DownloadRow: View {
    let r: DownloadRecord
    @ObservedObject var dm = DownloadManager.shared

    private func size(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(nsImage: r.destPath.map { NSWorkspace.shared.icon(forFile: $0) } ?? NSImage(systemSymbolName: "doc", accessibilityDescription: nil)!)
                .resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(r.filename).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                if r.state == .downloading {
                    ProgressView(value: r.progress).progressViewStyle(.linear)
                }
                Text(status).font(.caption2).foregroundColor(r.state == .failed ? .red : .secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            HStack(spacing: 2) {
                switch r.state {
                case .downloading:
                    icon("xmark.circle", L("取消")) { dm.cancel(r.id) }
                case .finished:
                    if dm.fileExists(r) {
                        icon("magnifyingglass", L("在访达中显示")) { dm.reveal(r) }
                        icon("arrow.up.forward.app", L("打开")) { dm.open(r) }
                    }
                case .failed, .cancelled:
                    if dm.canRetry(r) { icon("arrow.clockwise", L("重试")) { dm.retry(r.id) } }
                    if r.state == .failed { icon("safari", L("在浏览器中打开")) { dm.openInBrowser(r) } }
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var status: String {
        switch r.state {
        case .downloading:
            return r.total > 0 ? "\(r.toolName) · \(size(r.bytes)) / \(size(r.total))" : "\(r.toolName) · \(size(r.bytes))"
        case .finished:
            return "\(r.toolName) · \(size(r.bytes))" + (dm.fileExists(r) ? "" : L(" · 文件已移动或删除"))
        case .failed: return String(format: L("%@ · 失败：%@"), r.toolName, r.error ?? L("未知错误"))
        case .cancelled: return String(format: L("%@ · 已取消"), r.toolName)
        }
    }

    private func icon(_ name: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: name).frame(width: 22, height: 22) }
            .buttonStyle(.borderless).help(help).accessibilityLabel(help)
    }
}
