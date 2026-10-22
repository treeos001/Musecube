import AppKit
import SwiftUI
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    var window: NSWindow!
    let store = ToolStore()
    let rules = RuleStore()
    lazy var web = WebController(rules: rules)
    let quick = QuickOpenState()
    private var settingsWindow: NSWindow?
    private var aboutWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var appearanceObserver: NSObjectProtocol?
    private lazy var statusMenu: NSMenu = {
        let m = NSMenu()
        m.delegate = self
        m.addItem(withTitle: L("打开 Musecube"), action: #selector(openFromStatus(_:)), keyEquivalent: "").target = self
        m.addItem(withTitle: L("偏好设置…"), action: #selector(showSettings(_:)), keyEquivalent: ",").target = self
        m.addItem(.separator())
        let recent = m.addItem(withTitle: L("最近使用的工具"), action: nil, keyEquivalent: "")
        recent.submenu = NSMenu()
        m.addItem(.separator())
        m.addItem(withTitle: L("退出"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return m
    }()

    /// Launched by "Open at Login": stay in the menu bar only, no window.
    private var launchedAtLogin = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let e = NSAppleEventManager.shared().currentAppleEvent,
           e.eventID == AEEventID(kAEOpenApplication),
           e.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem) {
            launchedAtLogin = true
        }
        buildMenu()
        #if canImport(Sparkle) && !APPSTORE
        MainActor.assumeIsolated { Updates.setUp() } // no-op while appcast / key are placeholders
        #endif
        // Fit the first window to small screens (e.g. 13" MacBook Air at default scaling).
        let vf = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1280, height: 800)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: min(1000, vf.width * 0.85), height: min(700, vf.height * 0.85)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = L("Musecube")
        window.minSize = NSSize(width: 480, height: 360)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ContentView(store: store, web: web, quick: quick))
        window.center()
        window.setFrameAutosaveName("WebToolboxMain")
        window.delegate = self
        setUpStatusItem()
        applyAppearanceIcon()
        appearanceObserver = DistributedNotificationCenter.default.addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main) { [weak self] _ in
            self?.applyAppearanceIcon()
        }
        if !launchedAtLogin { applyDockPolicy() }
        NotificationCenter.default.addObserver(forName: .wtbDockIconChanged, object: nil, queue: .main) { [weak self] _ in
            self?.applyDockPolicy(); self?.showWindow()
        }
        if launchedAtLogin {
            NSApp.setActivationPolicy(.accessory) // menu bar only until the user opens the window
        } else {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        _ = DownloadManager.shared

        #if DEBUG
        // Debug-only test hook (not compiled into release builds made by build_app.sh).
        if let i = CommandLine.arguments.firstIndex(of: "--wtb-debug-url"), i + 1 < CommandLine.arguments.count {
            store.add(urlString: CommandLine.arguments[i + 1], name: "DLTest")
        }
        #endif

        NetworkMonitor.shared.onReconnect = { [weak self] in self?.web.networkDidReconnect() }

        HotKey.setHandler { [weak self] in self?.hotKeyPressed() }
        let result = HotKey.apply()
        if let text = hotKeyProblemText(result, HotKeyPrefs.combo) {
            DispatchQueue.main.async { [weak self] in
                let a = NSAlert()
                a.messageText = L("快捷键被占用")
                a.informativeText = text + "\n" + L("可以在设置里换一个组合键，或关闭全局快捷键。")
                a.addButton(withTitle: L("打开设置"))
                a.addButton(withTitle: L("稍后"))
                if a.runModal() == .alertFirstButtonReturn { self?.showSettings(nil) }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Close button only hides the main window; web views and their state stay alive.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === window else { return true }
        if !UserDefaults.standard.bool(forKey: "closeHintShown") {
            UserDefaults.standard.set(true, forKey: "closeHintShown")
            let a = NSAlert()
            a.messageText = L("已在菜单栏继续运行，⌘Q 可退出")
            a.addButton(withTitle: L("好"))
            a.beginSheetModal(for: window) { [weak self] _ in self?.window.orderOut(nil) }
            return false
        }
        window.orderOut(nil)
        return false
    }

    func applyDockPolicy() {
        NSApp.setActivationPolicy(DockPrefs.showDockIcon ? .regular : .accessory)
        applyAppearanceIcon()
    }

    private func applyAppearanceIcon() {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let name = dark ? "AppIconDark" : "AppIconLight"
        guard let url = Bundle.main.url(forResource: name, withExtension: "icns"),
              let image = NSImage(contentsOf: url) else { return }
        NSApp.applicationIconImage = image
    }

    private func statusBarImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18))
        for name in ["StatusBarIcon_36", "StatusBarIcon_54"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
                  let data = try? Data(contentsOf: url),
                  let rep = NSBitmapImageRep(data: data) else { continue }
            rep.size = NSSize(width: 18, height: 18)
            image.addRepresentation(rep)
        }
        image.isTemplate = true
        return image
    }

    /// Menu bar icon: left click shows/hides the main window, right click (or ⌃-click) opens the menu.
    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let b = item.button {
            b.imageScaling = .scaleProportionallyDown
            b.image = statusBarImage()
            b.toolTip = L("Musecube")
            b.target = self
            b.action = #selector(statusClicked(_:))
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
    }

    @objc private func statusClicked(_ sender: NSStatusBarButton) {
        let e = NSApp.currentEvent
        if e?.type == .rightMouseUp || e?.modifierFlags.contains(.control) == true {
            statusItem?.menu = statusMenu
            statusItem?.button?.performClick(nil)
            statusItem?.menu = nil
        } else if window.isVisible && NSApp.isActive {
            window.orderOut(nil)
        } else {
            NSApp.unhide(nil); showWindow()
        }
    }

    @objc func openFromStatus(_ sender: Any?) { NSApp.unhide(nil); showWindow() }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusMenu, let sub = menu.items.first(where: { $0.submenu != nil })?.submenu else { return }
        sub.removeAllItems()
        let recent = store.recentTools
        if recent.isEmpty { sub.addItem(withTitle: L("暂无"), action: nil, keyEquivalent: "").isEnabled = false }
        for t in recent {
            let i = sub.addItem(withTitle: t.name, action: #selector(openRecent(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = t.id.uuidString
            if let img = store.icon(for: t)?.copy() as? NSImage { img.size = NSSize(width: 16, height: 16); i.image = img }
        }
    }
    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? String, let id = UUID(uuidString: s) else { return }
        store.selectedID = id
        NSApp.unhide(nil); showWindow()
    }

    func showWindow() {
        if NSApp.activationPolicy() != (DockPrefs.showDockIcon ? .regular : .accessory) { applyDockPolicy() }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Global hotkey: show the window with Quick Open focused; pressing it again while it is open hides the app.
    func hotKeyPressed() {
        if NSApp.isActive && window.isKeyWindow && window.isVisible && quick.visible {
            quick.hide()
            NSApp.hide(nil)
        } else {
            NSApp.unhide(nil)
            showWindow()
            quick.show()
        }
    }

    @objc func showQuickOpen(_ sender: Any?) {
        showWindow()
        if quick.visible { quick.hide() } else { quick.show() }
    }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 340),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = L("设置")
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView())
            w.center()
            settingsWindow = w
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Bring to front; if already frontmost and key, hide.
    func toggleWindow() {
        if NSApp.isActive && window.isKeyWindow && window.isVisible {
            NSApp.hide(nil)
        } else {
            NSApp.unhide(nil)
            showWindow()
        }
    }

    /// ⌘W hides the window (app keeps running; Dock / hotkey brings it back).
    @objc func hideMainWindow(_ sender: Any?) { window.orderOut(nil) }

    @objc func reloadPage(_ sender: Any?) { web.reload() }
    @objc func goBack(_ sender: Any?) { web.goBack() }
    @objc func goForward(_ sender: Any?) { web.goForward() }
    @objc func zoomIn(_ sender: Any?) { web.zoomIn() }
    @objc func zoomOut(_ sender: Any?) { web.zoomOut() }
    @objc func zoomReset(_ sender: Any?) { web.zoomReset() }
    @objc func showFind(_ sender: Any?) { web.findVisible = true }
    @objc func toggleSidebar(_ sender: Any?) {
        let d = UserDefaults.standard
        d.set(!d.bool(forKey: "sidebarHidden"), forKey: "sidebarHidden")
    }
    @objc func selectTool(_ sender: NSMenuItem) {
        let tools = store.visibleTools
        if sender.tag < tools.count { store.selectedID = tools[sender.tag].id; showWindow() }
    }


    @objc func openFeedback(_ sender: Any?) { MainActor.assumeIsolated { openIssues() } }

    @objc func openDonate(_ sender: Any?) {
        guard let u = FeatureFlags.donationURL else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.open(u, configuration: cfg, completionHandler: nil)
    }
    #if canImport(Sparkle) && !APPSTORE
    @objc func checkForUpdates(_ sender: Any?) { MainActor.assumeIsolated { Updates.checkForUpdates() } }
    #endif

    @objc func showAbout(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        guard FeatureFlags.showDonationLinks, FeatureFlags.donationURL != nil else {
            NSApp.orderFrontStandardAboutPanel(options: [
                .applicationName: L("Musecube"),
                .credits: NSAttributedString(string: L("我是设计师和插画师。工作里常要用一些很棒的网页工具，不想每次都在浏览器的标签页里翻找，所以做了 Musecube，打开就能用。") + "\n\n" + L("所列工具名称、图标与商标归各自所有者所有，与本产品无隶属、合作或背书关系。")),
            ])
            return
        }
        if aboutWindow == nil { aboutWindow = makeAboutWindow() }
        aboutWindow?.makeKeyAndOrderFront(nil)
    }

    private func makeAboutWindow() -> NSWindow {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let columnWidth: CGFloat = 332
        func wrapping(_ text: String, size: CGFloat, weight: NSFont.Weight, secondary: Bool = false, column: Bool = false) -> NSTextField {
            let f = NSTextField(wrappingLabelWithString: text)
            f.font = .systemFont(ofSize: size, weight: weight)
            f.alignment = column ? .left : .center
            f.preferredMaxLayoutWidth = columnWidth
            if secondary { f.textColor = .secondaryLabelColor }
            if column {
                f.translatesAutoresizingMaskIntoConstraints = false
                f.widthAnchor.constraint(equalToConstant: columnWidth).isActive = true
            }
            return f
        }
        let icon = NSImageView()
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 72),
            icon.heightAnchor.constraint(equalToConstant: 72),
        ])
        let button = NSButton(title: L("Buy a Coffee for Shukuinan"), target: self, action: #selector(openDonate(_:)))
        button.bezelStyle = .rounded
        let feedback = NSButton(title: L("反馈"), target: self, action: #selector(openFeedback(_:)))
        feedback.bezelStyle = .rounded
        let stack = NSStackView(views: [
            icon,
            wrapping(L("Musecube"), size: 16, weight: .semibold),
            wrapping(version, size: 12, weight: .regular, secondary: true),
            wrapping(L("我是设计师和插画师。工作里常要用一些很棒的网页工具，不想每次都在浏览器的标签页里翻找，所以做了 Musecube，打开就能用。"), size: 13, weight: .regular, column: true),
            wrapping(L("Musecube 完全免费、开源。如果它帮到了你，欢迎请作者喝杯咖啡 ☕"), size: 13, weight: .regular, column: true),
            wrapping(L("所列工具名称、图标与商标归各自所有者所有，与本产品无隶属、合作或背书关系。"), size: 11, weight: .regular, secondary: true, column: true),
            button,
            feedback,
        ])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: 380),
        ])
        stack.layoutSubtreeIfNeeded()
        let fitted = stack.fittingSize
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: fitted.height),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = L("关于 Musecube")
        w.contentView = content
        w.isReleasedWhenClosed = false
        w.center()
        return w
    }

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        let aboutItem = appMenu.addItem(withTitle: L("关于 Musecube"), action: #selector(showAbout(_:)), keyEquivalent: "")
        aboutItem.target = self
        appMenu.addItem(.separator())
        let settingsItem = appMenu.addItem(withTitle: L("设置…"), action: #selector(showSettings(_:)), keyEquivalent: ",")
        settingsItem.target = self
        #if canImport(Sparkle) && !APPSTORE
        let upd = appMenu.addItem(withTitle: L("检查更新…"), action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        upd.target = self
        #endif
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("隐藏 Musecube"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("退出 Musecube"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: L("编辑"))
        edit.addItem(withTitle: L("撤销"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: L("重做"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: L("剪切"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L("复制"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L("粘贴"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L("全选"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        let viewItem = NSMenuItem(); main.addItem(viewItem)
        let view = NSMenu(title: L("显示"))
        func add(_ m: NSMenu, _ title: String, _ sel: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = [.command]) {
            let i = m.addItem(withTitle: title, action: sel, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = self
        }
        add(view, L("快速打开…"), #selector(showQuickOpen(_:)), "k")
        view.addItem(.separator())
        add(view, L("重新载入"), #selector(reloadPage(_:)), "r")
        add(view, L("后退"), #selector(goBack(_:)), "[")
        add(view, L("前进"), #selector(goForward(_:)), "]")
        view.addItem(.separator())
        add(view, L("放大"), #selector(zoomIn(_:)), "=")
        add(view, L("放大"), #selector(zoomIn(_:)), "+") // ⌘+ on layouts where + is direct
        view.items.last?.isHidden = true
        view.items.last?.allowsKeyEquivalentWhenHidden = true
        add(view, L("缩小"), #selector(zoomOut(_:)), "-")
        add(view, L("实际大小"), #selector(zoomReset(_:)), "0")
        view.addItem(.separator())
        add(view, L("查找…"), #selector(showFind(_:)), "f")
        add(view, L("显示/隐藏侧边栏"), #selector(toggleSidebar(_:)), "s", [.command, .control])
        view.addItem(.separator())
        for n in 1...9 {
            let i = view.addItem(withTitle: String(format: L("切换到第 %d 个工具"), n), action: #selector(selectTool(_:)), keyEquivalent: "\(n)")
            i.tag = n - 1
            i.target = self
        }
        viewItem.submenu = view


        let winItem = NSMenuItem(); main.addItem(winItem)
        let win = NSMenu(title: L("窗口"))
        win.addItem(withTitle: L("最小化"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        let hideWin = win.addItem(withTitle: L("关闭窗口"), action: #selector(hideMainWindow(_:)), keyEquivalent: "w")
        hideWin.target = self
        winItem.submenu = win
        NSApp.windowsMenu = win

        let helpItem = NSMenuItem(); main.addItem(helpItem)
        let help = NSMenu(title: L("帮助"))
        add(help, L("反馈"), #selector(openFeedback(_:)), "")
        if FeatureFlags.showDonationLinks, FeatureFlags.donationURL != nil {
            add(help, L("Buy a Coffee for Shukuinan"), #selector(openDonate(_:)), "")
        }
        helpItem.submenu = help
        NSApp.helpMenu = help

        NSApp.mainMenu = main
    }
}
