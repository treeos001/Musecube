import AppKit
import ChildPaneColorKit
import Combine
import WebKit

final class ChildPage: Identifiable, ObservableObject {
    let id = UUID()
    let webView: WKWebView
    let openerToolID: UUID
    let tabColor: ChildPaneTabColor
    @Published var title: String
    @Published var isExpanded: Bool
    var preferredWidth: CGFloat?
    var expandSequence: UInt64 = 0
    
    var onClose: (() -> Void)?
    
    init(webView: WKWebView, openerToolID: UUID, title: String, tabColor: ChildPaneTabColor, isExpanded: Bool = true) {
        self.webView = webView
        self.openerToolID = openerToolID
        self.title = title
        self.tabColor = tabColor
        self.isExpanded = isExpanded
    }
}

/// Main-area drop highlight only; isolated so toggling it does not rebuild child title/ear `NSView` hosts mid-drag.
final class ChildPaneMainDropHighlight: ObservableObject {
    @Published var isTargeted = false
}

final class ChildPaneManager: ObservableObject {
    static let shared = ChildPaneManager()

    @Published private(set) var childPages: [UUID: [ChildPage]] = [:]
    @Published private(set) var currentToolID: UUID?
    /// Active swap-drag child; not `@Published` so starting a drag does not rebuild child title/ear `NSView` hosts.
    private(set) var draggingChildID: UUID?
    let mainDropHighlight = ChildPaneMainDropHighlight()
    private var swapDragMonitor: Any?
    private var swapDragOnSwap: (() -> Void)?
    weak var mainWindow: NSWindow?
    weak var mainDropHostView: NSView?
    weak var mainWebViewBox: WebViewBox?
    private var childWebViewBoxes: [UUID: WeakWebViewBoxRef] = [:]
    @Published var tabAnchorGlobalFrame: CGRect = .zero
    @Published private(set) var earPanelReportsVisible = false
    @Published private(set) var mainContentWidth: CGFloat = 0
    @Published private(set) var earTabHeight: CGFloat = ChildPaneEarTabSizing.defaultMinHeight
    @Published private(set) var earTabNeedsScroll: Bool = false
    @Published var splitRatio: CGFloat = 0.5 {
        didSet { UserDefaults.standard.set(Double(splitRatio), forKey: "childPaneSplitRatio") }
    }
    @Published var mainPreferredWidth: CGFloat?
    
    var hasExpandedChild: Bool { !expandedChildren.isEmpty }
    var hasAnyChild: Bool { !currentToolChildren.isEmpty }
    
    var currentToolChildren: [ChildPage] {
        guard let tid = currentToolID else { return [] }
        return childPages[tid] ?? []
    }
    
    var expandedChildren: [ChildPage] {
        currentToolChildren.filter(\.isExpanded)
    }
    
    var collapsedChildren: [ChildPage] {
        currentToolChildren.filter { !$0.isExpanded }
    }

    var earTabLayoutWide: Bool {
        ChildPaneLayoutCapacity.isWideEarLayout(expandedChildCount: expandedChildren.count)
    }

    var earTabChildren: [ChildPage] { collapsedChildren }

    var earTabEmphasizeExpanded: Bool { false }

    private var nextExpandSequence: UInt64 = 0
    private var expandedCountAtLastAutoGrow = 0

    private var titleObservers: [UUID: NSKeyValueObservation] = [:]
    private static let tabColorsMigrationKey = "childPaneTabColorsMigrated"

    /// Reassigns the tool's child list so `@Published childPages` notifies SwiftUI after in-place `ChildPage` mutations (e.g. `isExpanded`).
    private func publishChildList(for toolID: UUID) {
        guard let pages = childPages[toolID] else { return }
        childPages[toolID] = pages
    }
    
    private init() {
        let saved = UserDefaults.standard.double(forKey: "childPaneSplitRatio")
        if saved > 0.2 && saved < 0.8 { splitRatio = CGFloat(saved) }
        if !UserDefaults.standard.bool(forKey: Self.tabColorsMigrationKey) {
            UserDefaults.standard.removeObject(forKey: "childPaneTabColors")
            UserDefaults.standard.set(true, forKey: Self.tabColorsMigrationKey)
        }
    }

    func setEarPanelVisible(_ visible: Bool) {
        guard earPanelReportsVisible != visible else { return }
        earPanelReportsVisible = visible
    }
    
    func setCurrentTool(_ toolID: UUID?) {
        finishSwapDragMonitor()
        draggingChildID = nil
        mainDropHighlight.isTargeted = false
        currentToolID = toolID
        if let tid = toolID {
            if childPages[tid] == nil { childPages[tid] = [] }
        }
        validateEarTabInvariant()
    }

    func noteMainContentWidth(_ width: CGFloat) {
        if mainContentWidth != width {
            mainContentWidth = width
        }
    }

    func currentLayout(contentWidth: CGFloat) -> ChildPaneLayoutResult {
        let expanded = expandedChildren
        let prefs = expanded.map(\.preferredWidth)
        return ChildPaneLayoutCapacity.layout(
            contentWidth: contentWidth,
            expandedCount: expanded.count,
            mainPreferred: mainPreferredWidth,
            childPreferred: prefs,
            splitRatio: splitRatio
        )
    }

    func dragMainChildDivider(delta: CGFloat) {
        guard let first = expandedChildren.first else { return }
        let layout = currentLayout(contentWidth: mainContentWidth)
        guard let firstW = layout.columnWidths.first else { return }
        let mainMin = mainPreferredWidth != nil
            ? ChildPaneLayoutMetrics.userAdjustMinMainWidth
            : ChildPaneLayoutMetrics.minMainWidth
        let childMin = first.preferredWidth != nil
            ? ChildPaneLayoutMetrics.userAdjustMinChildWidth
            : ChildPaneLayoutMetrics.compressedMinChildWidth
        let pair = ChildPaneLayoutCapacity.adjustAdjacentPair(
            leftWidth: layout.mainWidth,
            rightWidth: firstW,
            delta: delta,
            leftMin: mainMin,
            rightMin: childMin
        )
        mainPreferredWidth = pair.0
        first.preferredWidth = pair.1
        if let tid = currentToolID { publishChildList(for: tid) }
    }

    func dragChildDivider(leftID: UUID, rightID: UUID, delta: CGFloat) {
        guard let tid = currentToolID, let children = childPages[tid] else { return }
        guard let left = children.first(where: { $0.id == leftID }),
              let right = children.first(where: { $0.id == rightID }) else { return }
        let layout = currentLayout(contentWidth: mainContentWidth)
        let expanded = expandedChildren
        guard let li = expanded.firstIndex(where: { $0.id == leftID }),
              let ri = expanded.firstIndex(where: { $0.id == rightID }),
              ri == li + 1,
              li < layout.columnWidths.count, ri < layout.columnWidths.count else { return }
        let leftW = layout.columnWidths[li]
        let rightW = layout.columnWidths[ri]
        let leftMin = left.preferredWidth != nil
            ? ChildPaneLayoutMetrics.userAdjustMinChildWidth
            : ChildPaneLayoutMetrics.compressedMinChildWidth
        let rightMin = right.preferredWidth != nil
            ? ChildPaneLayoutMetrics.userAdjustMinChildWidth
            : ChildPaneLayoutMetrics.compressedMinChildWidth
        let pair = ChildPaneLayoutCapacity.adjustAdjacentPair(
            leftWidth: leftW,
            rightWidth: rightW,
            delta: delta,
            leftMin: leftMin,
            rightMin: rightMin
        )
        left.preferredWidth = pair.0
        right.preferredWidth = pair.1
        publishChildList(for: tid)
    }

    func resetMainChildDivider() {
        guard let first = expandedChildren.first else { return }
        let layout = currentLayout(contentWidth: mainContentWidth)
        guard let firstW = layout.columnWidths.first else { return }
        let pair = ChildPaneLayoutCapacity.evenPairDefault(leftWidth: layout.mainWidth, rightWidth: firstW)
        mainPreferredWidth = pair.0
        first.preferredWidth = pair.1
        if let tid = currentToolID { publishChildList(for: tid) }
    }

    func resetChildDivider(leftID: UUID, rightID: UUID) {
        guard let tid = currentToolID, let children = childPages[tid] else { return }
        guard let left = children.first(where: { $0.id == leftID }),
              let right = children.first(where: { $0.id == rightID }) else { return }
        let layout = currentLayout(contentWidth: mainContentWidth)
        let expanded = expandedChildren
        guard let li = expanded.firstIndex(where: { $0.id == leftID }),
              let ri = expanded.firstIndex(where: { $0.id == rightID }),
              li < layout.columnWidths.count, ri < layout.columnWidths.count else { return }
        let pair = ChildPaneLayoutCapacity.evenPairDefault(
            leftWidth: layout.columnWidths[li],
            rightWidth: layout.columnWidths[ri]
        )
        left.preferredWidth = pair.0
        right.preferredWidth = pair.1
        publishChildList(for: tid)
    }

    func updateEarTabSizing(tabHeight: CGFloat, needsScroll: Bool) {
        var changed = false
        if earTabHeight != tabHeight {
            earTabHeight = tabHeight
            changed = true
        }
        if earTabNeedsScroll != needsScroll {
            earTabNeedsScroll = needsScroll
            changed = true
        }
        if !changed { return }
    }

    private func validateEarTabInvariant() {
        let collapsed = collapsedChildren
        guard !collapsed.isEmpty else { return }
        guard let w = mainWindow, w.isVisible, !w.isMiniaturized, !NSApp.isHidden else { return }
        if !earPanelReportsVisible {
            #if DEBUG
            NSLog(
                "MCEAR: %ld collapsed child(ren) but ear panel not visible (expanded=%ld width=%.1f)",
                collapsed.count,
                expandedChildren.count,
                mainContentWidth
            )
            #endif
        }
    }

    func finishToolWindowTransition() {
        expandedCountAtLastAutoGrow = expandedChildren.count
        autoGrowMainWindowIfNeeded()
        validateEarTabInvariant()
    }

    private func autoGrowMainWindowIfNeeded() {
        guard let window = mainWindow else { return }
        if ToolWindowFrameCoordinator.shared.isAnimatingToolSwitch { return }
        let count = expandedChildren.count
        guard count > expandedCountAtLastAutoGrow else { return }
        expandedCountAtLastAutoGrow = count

        let layout = currentLayout(contentWidth: mainContentWidth)
        var delta = layout.requiredWindowGrowth
        guard delta > 0.5 else { return }

        let earMargin = earTabChildren.isEmpty ? 0 : ChildPaneLayoutMetrics.earTabPanelWidth
        guard let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame

        var frame = window.frame
        let maxGrowByScreen = visible.maxX - earMargin - frame.minX
        if maxGrowByScreen <= frame.width { return }
        let maxDelta = maxGrowByScreen - frame.width
        delta = min(delta, maxDelta)
        guard delta > 0.5 else { return }

        frame.size.width += delta
        if frame.maxX + earMargin > visible.maxX {
            let shift = frame.maxX + earMargin - visible.maxX
            frame.origin.x -= shift
        }
        if frame.minX < visible.minX {
            frame.origin.x = visible.minX
            let cap = visible.maxX - earMargin - frame.minX
            if cap < frame.width { frame.size.width = max(window.minSize.width, cap) }
        }
        if let tid = currentToolID {
            ToolWindowFrameCoordinator.shared.performProgrammaticFrame({
                window.setFrame(frame, display: true, animate: false)
            }, saveFor: tid)
        } else {
            window.setFrame(frame, display: true, animate: false)
        }
    }
    
    func noteMainDropZoneLayoutChanged() {
        if draggingChildID != nil, let id = draggingChildID {
            updateDrag(id)
        }
    }

    func mainDropScreenRect() -> NSRect? {
        guard let view = mainDropHostView, let window = view.window else { return nil }
        let inWindow = view.convert(view.bounds, to: nil)
        return window.convertToScreen(inWindow)
    }

    func isPointerOverMainDropZone() -> Bool {
        let mouse = NSEvent.mouseLocation
        guard let rect = mainDropScreenRect(), rect.width > 1, rect.height > 1 else { return false }
        return rect.contains(mouse)
    }

    var isSwapDragMonitorActive: Bool { swapDragMonitor != nil }

    /// After the press threshold, track drag/release at the event-monitor level so swap still completes if SwiftUI rebuilds the title/ear drag `NSView`.
    func beginSwapDrag(childID: UUID, onSwap: @escaping () -> Void) {
        draggingChildID = childID
        swapDragOnSwap = onSwap
        guard swapDragMonitor == nil else {
            updateDrag(childID)
            return
        }
        swapDragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self, let activeID = self.draggingChildID else { return event }
            switch event.type {
            case .leftMouseDragged:
                self.updateDrag(activeID)
                return event
            case .leftMouseUp:
                _ = self.completeSwapDrag(from: activeID)
                return event
            default:
                return event
            }
        }
        updateDrag(childID)
    }

    private func finishSwapDragMonitor() {
        if let swapDragMonitor { NSEvent.removeMonitor(swapDragMonitor) }
        swapDragMonitor = nil
        swapDragOnSwap = nil
    }

    func updateDrag(_ childID: UUID) {
        draggingChildID = childID
        let over = isPointerOverMainDropZone()
        if over != mainDropHighlight.isTargeted { mainDropHighlight.isTargeted = over }
    }

    /// Ends an in-flight swap drag once (monitor or `ChildPaneSwapDragView.mouseUp`).
    func completeSwapDrag(from childID: UUID) -> Bool {
        guard draggingChildID == childID else { return false }
        let swap = isPointerOverMainDropZone()
        let onSwap = swapDragOnSwap
        draggingChildID = nil
        mainDropHighlight.isTargeted = false
        finishSwapDragMonitor()
        if swap, let onSwap {
            DispatchQueue.main.async { onSwap() }
        }
        return swap
    }

    func registerMainWebViewBox(_ box: WebViewBox) { mainWebViewBox = box }
    func unregisterMainWebViewBox(_ box: WebViewBox) {
        if mainWebViewBox === box { mainWebViewBox = nil }
    }

    func registerChildWebViewBox(_ box: WebViewBox, childID: UUID) {
        childWebViewBoxes[childID] = WeakWebViewBoxRef(box)
    }

    func unregisterChildWebViewBox(_ box: WebViewBox, childID: UUID) {
        if childWebViewBoxes[childID]?.box === box { childWebViewBoxes.removeValue(forKey: childID) }
    }

    func scheduleSwapReconcile(web: WebController) {
        let work = { [weak self, weak web] in
            guard let self, let web else { return }
            self.reconcileWebViewHosting(web: web)
        }
        DispatchQueue.main.async(execute: work)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    func reconcileWebViewHosting(web: WebController) {
        mainWebViewBox?.adopt(web.webView)
        let wv = web.webView
        let superDesc = wv.superview.map { "\(type(of: $0))" } ?? "nil"
        let superPtr = wv.superview.map { Unmanaged.passUnretained($0).toOpaque() } ?? nil
        let superPart = superPtr.map { "\(superDesc)@\($0)" } ?? superDesc
        let wvPtr = Unmanaged.passUnretained(wv).toOpaque()
        let win = wv.window != nil ? 1 : 0
        #if DEBUG
        NSLog(
            "%@",
            "MCSWAP reconcile main wv=\(wvPtr) super=\(superPart) win=\(win) frame=\(NSStringFromRect(wv.frame))"
        )
        #endif
        for child in expandedChildren {
            childWebViewBoxes[child.id]?.box?.adopt(child.webView)
        }
    }

    /// Tool that owns a docked child web view (for popup docking when `owner` was cleared e.g. after swap).
    func openerToolID(for webView: WKWebView) -> UUID? {
        for children in childPages.values {
            if let page = children.first(where: { $0.webView === webView }) {
                return page.openerToolID
            }
        }
        return nil
    }

    func addChild(_ webView: WKWebView, openerToolID: UUID, title: String) -> ChildPage {
        let siblings = childPages[openerToolID] ?? []

        let siblingColors = siblings.map(\.tabColor)
        let color = ChildPaneColorAllocator.restoredColor(saved: nil, existingSiblingColors: siblingColors)
        let child = ChildPage(webView: webView, openerToolID: openerToolID, title: title, tabColor: color, isExpanded: true)

        var pages = childPages[openerToolID] ?? []
        pages.append(child)
        childPages[openerToolID] = pages
        
        child.expandSequence = nextExpandSequence
        nextExpandSequence += 1
        if currentToolID == openerToolID {
            autoGrowMainWindowIfNeeded()
            validateEarTabInvariant()
        }
        
        titleObservers[child.id] = webView.observe(\.title, options: [.new]) { [weak child] wv, _ in
            guard let child = child else { return }
            DispatchQueue.main.async {
                if let t = wv.title, !t.isEmpty { child.title = t }
            }
        }
        
        return child
    }
    
    func expand(_ childID: UUID) {
        guard let tid = currentToolID, let children = childPages[tid] else { return }
        guard let c = children.first(where: { $0.id == childID }) else { return }
        c.isExpanded = true
        c.expandSequence = nextExpandSequence
        nextExpandSequence += 1
        publishChildList(for: tid)
        autoGrowMainWindowIfNeeded()
        validateEarTabInvariant()
    }
    
    func collapse(_ childID: UUID) {
        guard let tid = currentToolID, let children = childPages[tid] else { return }
        if let c = children.first(where: { $0.id == childID }) {
            c.isExpanded = false
        }
        publishChildList(for: tid)
        validateEarTabInvariant()
    }

    
    private static func releaseChildWebViewResources(_ webView: WKWebView) {
        webView.stopLoading()
        webView.pauseAllMediaPlayback(completionHandler: nil)
        webView.closeAllMediaPresentations(completionHandler: nil)
        webView.setAllMediaPlaybackSuspended(true, completionHandler: nil)
        if let blank = URL(string: "about:blank") {
            webView.load(URLRequest(url: blank))
        }
    }

    func close(_ childID: UUID) {
        for tid in Array(childPages.keys) {
            guard var children = childPages[tid], let idx = children.firstIndex(where: { $0.id == childID }) else { continue }
            let child = children.remove(at: idx)
            Self.releaseChildWebViewResources(child.webView)
            titleObservers.removeValue(forKey: childID)
            childWebViewBoxes.removeValue(forKey: childID)
            child.onClose?()
            childPages[tid] = children
            if currentToolID == tid { validateEarTabInvariant() }
            return
        }
    }

    /// Remove a child from the pane without stopping its web view. Used when that page becomes the main page.
    func detach(_ childID: UUID) -> ChildPage? {
        for tid in Array(childPages.keys) {
            guard var children = childPages[tid], let idx = children.firstIndex(where: { $0.id == childID }) else { continue }
            let child = children.remove(at: idx)
            childPages[tid] = children
            titleObservers.removeValue(forKey: childID)
            child.isExpanded = false
            if currentToolID == tid { validateEarTabInvariant() }
            return child
        }
        return nil
    }
    
    func closeAllForTool(_ toolID: UUID) {
        guard let children = childPages[toolID] else { return }
        for c in children {
            Self.releaseChildWebViewResources(c.webView)
            titleObservers.removeValue(forKey: c.id)
            childWebViewBoxes.removeValue(forKey: c.id)
            c.onClose?()
        }
        childPages[toolID] = []
        if currentToolID == toolID { validateEarTabInvariant() }
    }

    static func shouldDockPopup(url: URL?, windowFeatures: WKWindowFeatures, fromContextMenu: Bool = false) -> Bool {
        let w = windowFeatures.width.map { CGFloat(truncating: $0) }
        let h = windowFeatures.height.map { CGFloat(truncating: $0) }
        return ChildPaneDockURLPolicy.shouldDockPopup(url: url, width: w, height: h, fromContextMenu: fromContextMenu)
    }

    static func isAuthURL(_ url: URL) -> Bool { ChildPaneDockURLPolicy.isAuthURL(url) }

    static func isPaymentURL(_ url: URL) -> Bool { ChildPaneDockURLPolicy.isPaymentURL(url) }
}

private struct WeakWebViewBoxRef {
    weak var box: WebViewBox?
    init(_ box: WebViewBox) { self.box = box }
}
