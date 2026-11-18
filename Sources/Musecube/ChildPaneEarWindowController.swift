import AppKit
import ChildPaneColorKit
import SwiftUI
import Combine

struct ChildPaneTabAnchorKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

final class ChildPaneEarWindowController: NSObject {
    private weak var parentWindow: NSWindow?
    private var panel: NSPanel?
    private var hostingView: NSHostingView<ChildPaneEarPanelRoot>?
    private var cancellables = Set<AnyCancellable>()
    private var frameObs: NSObjectProtocol?
    private var lifecycleObs: [NSObjectProtocol] = []
    private var zOrderObs: [NSObjectProtocol] = []
    private var workspaceObs: NSObjectProtocol?
    private var prefObs: NSObjectProtocol?
    private var tornDown = false
    private var observersInstalled = false
    private var fullscreenTransition = false
    private var pendingReposition: DispatchWorkItem?

    func attach(to parent: NSWindow) {
        parentWindow = parent
        tornDown = false
        let panelW = ChildPaneMetrics.earTabWidth + 2
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelW, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .normal
        p.hidesOnDeactivate = false
        p.isFloatingPanel = false
        p.becomesKeyOnlyIfNeeded = true
        p.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        p.ignoresMouseEvents = false
        p.isReleasedWhenClosed = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: panelW, height: 200))
        let host = NSHostingView(rootView: ChildPaneEarPanelRoot())
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = true
        host.autoresizingMask = [.width, .height]
        host.frame = container.bounds
        container.addSubview(host)
        p.contentView = container
        panel = p
        hostingView = host

        let mgr = ChildPaneManager.shared
        mgr.$tabAnchorGlobalFrame
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleReposition() }
            .store(in: &cancellables)
        mgr.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleReposition() }
            .store(in: &cancellables)
        mgr.$currentToolID
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleReposition() }
            .store(in: &cancellables)

        installObservers(on: parent)
        repositionNow()
    }

    func suspendForOrderedOutMainWindow() {
        guard !tornDown else { return }
        removeWindowObservers()
        hideEarPanel()
    }

    func resumeForShownMainWindow() {
        guard !tornDown, let parent = parentWindow else { return }
        if !observersInstalled { installObservers(on: parent) }
        repositionNow()
    }

    func detach() {
        guard !tornDown else { return }
        tornDown = true
        pendingReposition?.cancel()
        pendingReposition = nil
        removeWindowObservers()
        cancellables.removeAll()
        if let parent = parentWindow, let panel = panel {
            detachEarChildWindow(parent: parent, panel: panel)
        }
        panel?.close()
        panel = nil
        hostingView = nil
        parentWindow = nil
        ChildPaneManager.shared.setEarPanelVisible(false)
    }

    deinit { detach() }

    private func installObservers(on parent: NSWindow) {
        guard !observersInstalled else { return }
        observersInstalled = true
        let nc = NotificationCenter.default
        frameObs = nc.addObserver(forName: NSWindow.didResizeNotification, object: parent, queue: .main) { [weak self] _ in
            self?.scheduleReposition()
        }
        lifecycleObs.append(nc.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: parent, queue: .main) { [weak self] _ in
            self?.scheduleReposition()
        })
        lifecycleObs.append(nc.addObserver(forName: NSWindow.willCloseNotification, object: parent, queue: .main) { [weak self] _ in
            self?.detach()
        })
        lifecycleObs.append(nc.addObserver(forName: NSWindow.willMiniaturizeNotification, object: parent, queue: .main) { [weak self] _ in
            self?.hideEarPanel()
        })
        lifecycleObs.append(nc.addObserver(forName: NSWindow.didDeminiaturizeNotification, object: parent, queue: .main) { [weak self] _ in
            self?.scheduleReposition()
        })
        lifecycleObs.append(nc.addObserver(forName: NSWindow.didChangeScreenNotification, object: parent, queue: .main) { [weak self] _ in
            self?.scheduleReposition()
        })
        lifecycleObs.append(nc.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: parent, queue: .main) { [weak self] _ in
            self?.beginFullscreenTransition()
        })
        lifecycleObs.append(nc.addObserver(forName: NSWindow.willExitFullScreenNotification, object: parent, queue: .main) { [weak self] _ in
            self?.beginFullscreenTransition()
        })
        lifecycleObs.append(nc.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: parent, queue: .main) { [weak self] _ in
            self?.endFullscreenTransition()
        })
        lifecycleObs.append(nc.addObserver(forName: NSWindow.didExitFullScreenNotification, object: parent, queue: .main) { [weak self] _ in
            self?.endFullscreenTransition()
        })
        lifecycleObs.append(nc.addObserver(forName: NSApplication.didHideNotification, object: nil, queue: .main) { [weak self] _ in
            self?.hideEarPanel()
        })
        lifecycleObs.append(nc.addObserver(forName: NSApplication.didUnhideNotification, object: nil, queue: .main) { [weak self] _ in
            self?.scheduleReposition()
        })
        let zNames: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.didResignMainNotification,
            NSWindow.didChangeOcclusionStateNotification,
        ]
        for name in zNames {
            zOrderObs.append(nc.addObserver(forName: name, object: parent, queue: .main) { [weak self] _ in
                self?.syncEarZOrder()
            })
        }
        zOrderObs.append(nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.syncEarZOrder()
        })
        zOrderObs.append(nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.syncEarZOrder()
        })
        workspaceObs = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.beginFullscreenTransition()
            DispatchQueue.main.async { self?.endFullscreenTransition() }
        }
        prefObs = nc.addObserver(forName: .wtbEarTabsFullScreenPrefChanged, object: nil, queue: .main) { [weak self] _ in
            self?.scheduleReposition()
        }
    }

    private func removeWindowObservers() {
        guard observersInstalled else { return }
        observersInstalled = false
        let nc = NotificationCenter.default
        if let frameObs {
            nc.removeObserver(frameObs)
            self.frameObs = nil
        }
        lifecycleObs.forEach { nc.removeObserver($0) }
        lifecycleObs.removeAll()
        zOrderObs.forEach { nc.removeObserver($0) }
        zOrderObs.removeAll()
        if let workspaceObs {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObs)
            self.workspaceObs = nil
        }
        if let prefObs {
            nc.removeObserver(prefObs)
            self.prefObs = nil
        }
    }

    private func beginFullscreenTransition() {
        fullscreenTransition = true
        panel?.alphaValue = 0
        if let panel, panel.isVisible {
            panel.orderOut(nil)
            ChildPaneManager.shared.setEarPanelVisible(false)
        }
    }

    private func endFullscreenTransition() {
        fullscreenTransition = false
        panel?.alphaValue = 1
        scheduleReposition()
    }

    private func scheduleReposition() {
        pendingReposition?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.fullscreenTransition else { return }
            self.repositionNow()
        }
        pendingReposition = work
        DispatchQueue.main.async(execute: work)
    }

    private func earIsChild(of parent: NSWindow, panel: NSWindow) -> Bool {
        panel.parent === parent || parent.childWindows?.contains(panel) == true
    }

    private func attachEarChildWindow(parent: NSWindow, panel: NSPanel) {
        guard !earIsChild(of: parent, panel: panel) else { return }
        if let otherParent = panel.parent, otherParent !== parent {
            otherParent.removeChildWindow(panel)
        }
        parent.addChildWindow(panel, ordered: .above)
    }

    private func detachEarChildWindow(parent: NSWindow, panel: NSPanel) {
        if earIsChild(of: parent, panel: panel) {
            parent.removeChildWindow(panel)
        }
    }

    private func hideEarPanel() {
        guard let parent = parentWindow, let panel = panel else { return }
        detachEarChildWindow(parent: parent, panel: panel)
        panel.orderOut(nil)
        ChildPaneManager.shared.setEarPanelVisible(false)
    }

    private func shouldShowEarPanel(parent: NSWindow, children: [ChildPage]) -> Bool {
        guard parent.isVisible, !parent.isMiniaturized, !NSApp.isHidden else { return false }
        guard !children.isEmpty else { return false }
        if parentIsFullScreen(parent), ChildPaneEarPrefs.hideEarTabsInFullScreen { return false }
        return true
    }

    private func parentIsFullScreen(_ parent: NSWindow) -> Bool {
        parent.styleMask.contains(.fullScreen)
    }

    private func syncEarZOrder() {
        guard let parent = parentWindow, let panel = panel, panel.isVisible, parent.isVisible, !parent.isMiniaturized else { return }
        if earIsChild(of: parent, panel: panel) {
            if panel.parent !== parent {
                parent.addChildWindow(panel, ordered: .above)
            }
            return
        }
        panel.order(.above, relativeTo: parent.windowNumber)
    }

    private func repositionNow() {
        guard !tornDown, !fullscreenTransition, let parent = parentWindow, let panel = panel else { return }
        let manager = ChildPaneManager.shared
        let children = manager.earTabChildren
        guard shouldShowEarPanel(parent: parent, children: children) else {
            hideEarPanel()
            return
        }

        let contentLayout = parent.contentLayoutRect
        let availableTabs = max(
            0,
            contentLayout.height - ChildPaneEarTabSizing.defaultBottomInset
        )
        let sizing = ChildPaneEarTabSizing.uniformHeight(available: availableTabs, count: children.count)
        manager.updateEarTabSizing(tabHeight: sizing.tabHeight, needsScroll: sizing.needsScroll)
        let panelW = ChildPaneMetrics.earTabWidth + 2
        let panelH = sizing.panelHeight
        let fullScreen = parentIsFullScreen(parent)
        let contentScreen = parent.convertToScreen(contentLayout)
        let visibleFrame = screenVisibleFrame(for: parent, fullScreen: fullScreen, contentScreen: contentScreen, panelW: panelW)
        let input = ChildPaneEarPanelFrameLayout.Inputs(
            parentFrame: parent.frame,
            contentLayoutInScreen: contentScreen,
            visibleFrame: visibleFrame,
            panelWidth: panelW,
            panelHeight: panelH,
            fullScreen: fullScreen
        )
        let screenRect = ChildPaneEarPanelFrameLayout.frame(for: input)
        attachEarChildWindow(parent: parent, panel: panel)
        if !panel.isVisible {
            panel.orderFront(nil)
        }
        applyPanelFrame(panel, screenRect)
        syncEarZOrder()
        ChildPaneManager.shared.setEarPanelVisible(true)
    }

    private func screenVisibleFrame(
        for parent: NSWindow,
        fullScreen: Bool,
        contentScreen: CGRect,
        panelW: CGFloat
    ) -> CGRect {
        let probeX = fullScreen ? contentScreen.maxX - panelW * 0.5 : parent.frame.maxX + panelW * 0.5
        let probe = NSPoint(x: probeX, y: parent.frame.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(probe) } ?? parent.screen ?? NSScreen.main
        return screen?.visibleFrame ?? contentScreen
    }

    private func applyPanelFrame(_ panel: NSPanel, _ screenRect: NSRect) {
        if !NSEqualRects(panel.frame, screenRect) {
            panel.setFrame(screenRect, display: true)
        }
        if let container = panel.contentView {
            let bounds = NSRect(origin: .zero, size: screenRect.size)
            if !NSEqualRects(container.frame, bounds) {
                container.frame = bounds
            }
            if let hostingView, !NSEqualRects(hostingView.frame, bounds) {
                hostingView.frame = bounds
            }
        }
    }
}

private struct ChildPaneEarPanelRoot: View {
    @ObservedObject private var manager = ChildPaneManager.shared

    var body: some View {
        let children = manager.earTabChildren
        if children.isEmpty {
            Color.clear.frame(width: 0, height: 0)
        } else {
            CollapsedChildTabs(
                manager: manager,
                children: children,
                tabHeight: manager.earTabHeight,
                emphasizeExpanded: manager.earTabEmphasizeExpanded,
                onSwapToMain: { child in
                    NotificationCenter.default.post(name: .childPaneSwapToMain, object: child.id)
                }
            )
            .frame(width: ChildPaneMetrics.earTabWidth + 2)
            .fixedSize(horizontal: true, vertical: true)
        }
    }
}

extension Notification.Name {
    static let childPaneSwapToMain = Notification.Name("childPaneSwapToMain")
    static let wtbEarTabsFullScreenPrefChanged = Notification.Name("wtbEarTabsFullScreenPrefChanged")
}

enum ChildPaneEarPrefs {
    static let hideInFullScreenKey = "hideEarTabsInFullScreen"
    static var hideEarTabsInFullScreen: Bool {
        get { UserDefaults.standard.object(forKey: hideInFullScreenKey) as? Bool ?? false }
        set {
            UserDefaults.standard.set(newValue, forKey: hideInFullScreenKey)
            NotificationCenter.default.post(name: .wtbEarTabsFullScreenPrefChanged, object: nil)
        }
    }
}