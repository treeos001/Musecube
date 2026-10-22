import AppKit
import SwiftUI
import ServiceManagement

extension Notification.Name {
    static let wtbHotKeyChanged = Notification.Name("wtbHotKeyChanged")
    static let wtbDockIconChanged = Notification.Name("wtbDockIconChanged")
}

/// "Show icon in Dock" (default on). Off = .accessory activation policy; the menu bar icon stays.
enum DockPrefs {
    static let key = "showDockIcon"
    static var showDockIcon: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

func hotKeyProblemText(_ r: HotKey.Result, _ c: HotKeyCombo) -> String? {
    switch r {
    case .ok, .disabled: return nil
    case .taken: return String(format: L("快捷键 %@ 已被其他应用占用，请换一个组合。"), c.display)
    case .systemConflict: return String(format: L("快捷键 %@ 与 macOS 系统快捷键冲突（系统设置 → 键盘 → 键盘快捷键），可能无法呼出。"), c.display)
    case .failed(let s): return String(format: L("快捷键 %@ 注册失败（错误 %d）。"), c.display, Int(s))
    }
}

/// Settings → global hotkey: record a new combo, reset, or turn the hotkey off.
struct SettingsView: View {
    @State private var enabled = HotKeyPrefs.enabled
    @State private var combo = HotKeyPrefs.combo
    @State private var recording = false
    @State private var problem: String?
    @State private var monitor: Any?
    @State private var showDock = DockPrefs.showDockIcon
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section(L("通用")) {
                Toggle(L("在程序坞显示图标"), isOn: $showDock)
                    .onChange(of: showDock) { _, v in
                        DockPrefs.showDockIcon = v
                        NotificationCenter.default.post(name: .wtbDockIconChanged, object: nil)
                    }
                Toggle(L("开机自动启动"), isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { _, v in
                        do {
                            if v { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                            openAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                if let e = loginError { Text(e).font(.caption).foregroundColor(.orange) }
                Text(L("关闭后只在菜单栏显示图标。点击窗口的关闭按钮只会隐藏窗口，不会退出 App。开机自动启动时只在菜单栏显示，不弹出窗口。"))
                    .font(.caption).foregroundColor(.secondary)
            }
            Section(L("全局快捷键")) {
                Toggle(L("启用全局快捷键（在任何应用中呼出快速打开）"), isOn: $enabled)
                    .onChange(of: enabled) { _, v in HotKeyPrefs.enabled = v; applyAndReport() }
                HStack {
                    Text(L("快捷键"))
                    Spacer()
                    Button(recording ? L("请按下新的组合键…（Esc 取消）") : combo.display) {
                        recording ? stopRecording() : startRecording()
                    }
                    .disabled(!enabled)
                    Button(L("恢复默认")) {
                        combo = .defaultCombo; HotKeyPrefs.combo = combo; applyAndReport()
                    }
                    .disabled(!enabled || combo == .defaultCombo)
                }
                if let p = problem, enabled {
                    Label(p, systemImage: "exclamationmark.triangle.fill").foregroundColor(.orange).font(.callout)
                }
                Text(L("组合键至少要包含 ⌘、⌥ 或 ⌃ 之一。主窗口内也可以按 ⌘K 打开快速打开。"))
                    .font(.caption).foregroundColor(.secondary)
                Text(L("如果按快捷键没有反应，可能是其他 App 已经占用了这个组合键，请换一个。"))
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onAppear { problem = hotKeyProblemText(HotKey.lastResult, combo) }
        .onDisappear { stopRecording() }
    }

    private func applyAndReport() {
        let r = HotKey.apply()
        problem = hotKeyProblemText(r, HotKeyPrefs.combo)
        NotificationCenter.default.post(name: .wtbHotKeyChanged, object: nil)
    }

    private func startRecording() {
        recording = true
        HotKey.unregister() // so the current combo can be re-recorded / probed
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { stopRecording(); HotKey.apply(); return nil } // Esc
            guard let c = HotKeyCombo(event: e) else { NSSound.beep(); return nil }
            combo = c
            HotKeyPrefs.combo = c
            stopRecording()
            applyAndReport()
            return nil
        }
    }

    private func stopRecording() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}
