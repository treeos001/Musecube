import AppKit
import ChildPaneColorKit
import SwiftUI
import WebKit

enum ChildPaneMetrics {
    static let earTabWidth: CGFloat = 34
    static let earTabMinHeight: CGFloat = ChildPaneEarTabSizing.defaultMinHeight
    static let earTabMaxHeight: CGFloat = ChildPaneEarTabSizing.defaultMaxHeight
    static let earStackSpacing: CGFloat = 0
    static let earStackBottomInset: CGFloat = ChildPaneEarTabSizing.defaultBottomInset
    static let minMainWidth: CGFloat = ChildPaneLayoutMetrics.minMainWidth
    static let minChildWidth: CGFloat = ChildPaneLayoutMetrics.minChildWidth
    static let compressedMinChildWidth: CGFloat = ChildPaneLayoutMetrics.compressedMinChildWidth
    static let mainChildSplitChrome: CGFloat = ChildPaneLayoutMetrics.mainChildSplitChrome
    static let columnDividerWidth: CGFloat = ChildPaneLayoutMetrics.columnDividerWidth

    static var splitDividerColor: Color { Color(nsColor: .separatorColor) }
}

struct ChildPaneView: View {
    @ObservedObject var manager: ChildPaneManager
    let columnWidths: [CGFloat]
    let onSwapToMain: (ChildPage) -> Void
    
    var body: some View {
        let expanded = manager.expandedChildren
        if expanded.isEmpty {
            EmptyView()
        } else {
            HStack(spacing: 0) {
                ForEach(Array(expanded.enumerated()), id: \.element.id) { index, child in
                    let width = index < columnWidths.count ? columnWidths[index] : (columnWidths.last ?? 320)
                    if index > 0 {
                        ChildColumnDividerLine()
                    }
                    ExpandedChildPane(child: child, manager: manager, onSwapToMain: onSwapToMain)
                        .frame(width: width)
                }
            }
            .overlay {
                ChildPaneDividerOverlaySurface(
                    dividerCenters: ChildPaneColumnDividerHitTest.childGroupDividerCenterXs(columnWidths: columnWidths)
                ) { index, delta in
                    let pair = expanded.indices.contains(index + 1)
                        ? (expanded[index], expanded[index + 1])
                        : nil
                    if let pair {
                        manager.dragChildDivider(leftID: pair.0.id, rightID: pair.1.id, delta: delta)
                    }
                } onDoubleClick: { index in
                    let pair = expanded.indices.contains(index + 1)
                        ? (expanded[index], expanded[index + 1])
                        : nil
                    if let pair {
                        manager.resetChildDivider(leftID: pair.0.id, rightID: pair.1.id)
                    }
                }
            }
        }
    }
}

private struct ChildColumnDividerLine: View {
    var body: some View {
        Rectangle()
            .fill(ChildPaneMetrics.splitDividerColor)
            .frame(width: ChildPaneMetrics.columnDividerWidth)
            .allowsHitTesting(false)
    }
}

struct ExpandedChildPane: View {
    @ObservedObject var child: ChildPage
    @ObservedObject var manager: ChildPaneManager
    let onSwapToMain: (ChildPage) -> Void
    
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        VStack(spacing: 0) {
            ChildPaneTitleBar(
                childID: child.id,
                title: child.title,
                onCollapse: { manager.collapse(child.id) },
                onClose: { manager.close(child.id) },
                onSwap: { onSwapToMain(child) }
            )
            
            WebViewHost(webView: child.webView, role: .child(child.id))
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct ChildPaneTitleBar: View {
    let childID: UUID
    let title: String
    let onCollapse: () -> Void
    let onClose: () -> Void
    let onSwap: () -> Void
    
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovering = false
    
    private var displayTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? L("子页面") : t
    }
    
    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .help(L("拖到主区域可交换位置"))
                    .accessibilityLabel(L("拖动手柄"))
                    .allowsHitTesting(false)
                
                Text(displayTitle)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(displayTitle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
            .background {
                ChildPaneSwapDragSurface(childID: childID, onSwap: onSwap)
            }
            
            HStack(spacing: 2) {
                Button(action: onCollapse) {
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(L("收起到标签"))
                .accessibilityLabel(L("收起子页面"))
                
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(L("关闭"))
                .accessibilityLabel(L("关闭子页面"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(ChildPaneChrome.titleBarFill(colorScheme: colorScheme, emphasized: hovering))
        .overlay(alignment: .bottom) {
            Divider().opacity(0.65)
        }
        .onHover { h in
            hovering = h
            if h { NSCursor.openHand.push() } else { NSCursor.pop() }
        }
    }
}

struct CollapsedChildTabs: View {
    @ObservedObject var manager: ChildPaneManager
    let children: [ChildPage]
    let tabHeight: CGFloat
    var emphasizeExpanded = false
    let onSwapToMain: (ChildPage) -> Void
    
    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: ChildPaneMetrics.earStackSpacing) {
                ForEach(Array(children.enumerated()), id: \.element.id) { index, child in
                    CollapsedChildTab(
                        child: child,
                        tabHeight: tabHeight,
                        showsTopHairline: index > 0 && children[index - 1].tabColor == child.tabColor,
                        emphasized: emphasizeExpanded && child.isExpanded,
                        onExpand: { manager.expand(child.id) },
                        onClose: { manager.close(child.id) },
                        onSwapToMain: { onSwapToMain(child) }
                    )
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.trailing, 1)
            .padding(.bottom, ChildPaneMetrics.earStackBottomInset)
        }
        .frame(width: ChildPaneMetrics.earTabWidth)
        .background(Color.clear)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("子页面标签"))
    }
}

struct CollapsedChildTab: View {
    @ObservedObject var child: ChildPage
    let tabHeight: CGFloat
    var showsTopHairline = false
    var emphasized = false
    let onExpand: () -> Void
    let onClose: () -> Void
    let onSwapToMain: () -> Void
    
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var dragged = false
    
    private var showChrome: Bool { hovering || emphasized }
    private var outlineInset: CGFloat { 1 }
    
    var body: some View {
        let shape = ExteriorFolderEarShape()
        ZStack(alignment: .topTrailing) {
            shape
                .fill(child.tabColor.fill(hovering: hovering))
                .overlay {
                    if emphasized {
                        shape.inset(by: outlineInset).stroke(Color.accentColor, lineWidth: 2)
                    } else {
                        shape.stroke(Color.black.opacity(0.14), lineWidth: 0.75)
                    }
                }
                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.28 : 0.1), radius: emphasized ? 2 : 1, x: 1, y: 0)
            
            if showsTopHairline {
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(ChildPaneMetrics.splitDividerColor)
                        .frame(height: 1)
                    Spacer(minLength: 0)
                }
                .allowsHitTesting(false)
            }
            
            VStack(spacing: 4) {
                Text(earDisplayTitle)
                    .font(.system(size: 10, weight: emphasized ? .semibold : .medium))
                    .foregroundStyle(child.tabColor.earTabTitleColor(colorScheme: colorScheme))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: max(8, tabHeight - 22))
                    .rotationEffect(.degrees(-90))
                    .fixedSize(horizontal: false, vertical: true)
                    .help(child.title)
                    .allowsHitTesting(false)
            }
            .frame(width: ChildPaneMetrics.earTabWidth, height: tabHeight)
            .padding(.trailing, 1)
            .background {
                ChildPaneSwapDragSurface(
                    childID: child.id,
                    onSwap: onSwapToMain,
                    onTapIfNoDrag: { if !dragged { onExpand() } },
                    onDragBegan: { dragged = true },
                    onDragEnded: { DispatchQueue.main.async { dragged = false } }
                )
            }
            
            if showChrome {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .padding(3)
                .transition(reduceMotion ? .identity : .opacity)
                .accessibilityLabel(L("关闭子页面"))
            }
        }
        .frame(width: ChildPaneMetrics.earTabWidth, height: tabHeight)
        .contentShape(shape)
        .onHover { hovering = $0 }
        .focusable(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(child.title)
        .accessibilityHint(L("点击展开，拖到主区域可交换位置"))
        .accessibilityAddTraits(.isButton)
        .contextMenu {
            Button(L("展开")) { onExpand() }
            Button(L("移到主区域")) { onSwapToMain() }
            Divider()
            Button(L("关闭")) { onClose() }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hovering)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: emphasized)
    }
    
    private var earDisplayTitle: String {
        child.title
            .replacingOccurrences(of: " - ", with: "\u{00A0}-\u{00A0}")
            .replacingOccurrences(of: "-", with: "\u{2011}")
    }
}

/// Tab ear outside the window: flat left edge, rounded outer right corners.
struct ExteriorFolderEarShape: Shape {
    func path(in rect: CGRect) -> Path {
        Self.earPath(in: rect)
    }

    func inset(by amount: CGFloat) -> some InsettableShape {
        InsetExteriorFolderEarShape(inset: amount)
    }

    static func earPath(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width
        let h = rect.height
        let r: CGFloat = 6
        p.move(to: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: w - r, y: 0))
        p.addQuadCurve(to: CGPoint(x: w, y: r), control: CGPoint(x: w, y: 0))
        p.addLine(to: CGPoint(x: w, y: h - r))
        p.addQuadCurve(to: CGPoint(x: w - r, y: h), control: CGPoint(x: w, y: h))
        p.addLine(to: CGPoint(x: 0, y: h))
        p.closeSubpath()
        return p
    }
}

private struct InsetExteriorFolderEarShape: InsettableShape {
    var inset: CGFloat

    func path(in rect: CGRect) -> Path {
        ExteriorFolderEarShape.earPath(in: rect.insetBy(dx: inset, dy: inset))
    }

    func inset(by amount: CGFloat) -> InsetExteriorFolderEarShape {
        var s = self
        s.inset += amount
        return s
    }
}

private enum ChildPaneChrome {
    static func titleBarFill(colorScheme: ColorScheme, emphasized: Bool) -> Color {
        let c = Color(nsColor: colorScheme == .dark ? .controlBackgroundColor : .windowBackgroundColor)
        return c.opacity(emphasized ? 0.95 : 0.82)
    }
}

struct MainDropZone: View {
    let isTargeted: Bool
    
    var body: some View {
        if isTargeted {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 4]))
                .background(Color.accentColor.opacity(0.1))
                .padding(4)
                .allowsHitTesting(false)
        }
    }
}

final class DividerOverlayView: NSView {
    var dividerCenters: [CGFloat] = []
    var onDrag: ((Int, CGFloat) -> Void)?
    var onDoubleClick: ((Int) -> Void)?

    private var dragStartX: CGFloat = 0
    private var activeDividerIndex: Int?

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override var isOpaque: Bool { false }

    override var focusRingType: NSFocusRingType {
        get { .none }
        set { }
    }

  private var grabHalfWidth: CGFloat { ChildPaneColumnDividerHitTest.grabHalfWidth }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        return dividerIndex(at: point.x) != nil ? self : nil
    }

    private func dividerIndex(at x: CGFloat) -> Int? {
        ChildPaneColumnDividerHitTest.dividerIndex(atX: x, centers: dividerCenters, halfWidth: grabHalfWidth)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        let h = bounds.height
        for center in dividerCenters {
            let r = NSRect(x: center - grabHalfWidth, y: 0, width: ChildPaneColumnDividerHitTest.grabWidth, height: h)
            addCursorRect(r, cursor: .resizeLeftRight)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        guard !dividerCenters.isEmpty else { return }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if dividerIndex(at: point.x) != nil {
            NSCursor.resizeLeftRight.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func mouseEntered(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        guard event.buttonNumber == 0 else {
            super.mouseDown(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        guard let index = dividerIndex(at: point.x) else { return }
        if event.clickCount >= 2 {
            onDoubleClick?(index)
            return
        }
        activeDividerIndex = index
        dragStartX = event.locationInWindow.x
    }

    override func mouseDragged(with event: NSEvent) {
        guard event.buttonNumber == 0, event.clickCount < 2, let index = activeDividerIndex else { return }
        let delta = event.locationInWindow.x - dragStartX
        guard abs(delta) > 0.001 else { return }
        onDrag?(index, delta)
        dragStartX = event.locationInWindow.x
    }

    override func mouseUp(with event: NSEvent) {
        activeDividerIndex = nil
        super.mouseUp(with: event)
    }
}

struct ChildPaneDividerOverlaySurface: NSViewRepresentable {
    let dividerCenters: [CGFloat]
    var onDrag: (Int, CGFloat) -> Void
    var onDoubleClick: (Int) -> Void

    func makeNSView(context: Context) -> DividerOverlayView {
        let view = DividerOverlayView()
        view.wantsLayer = true
        view.layer?.masksToBounds = false
        apply(to: view)
        return view
    }

    func updateNSView(_ view: DividerOverlayView, context: Context) {
        apply(to: view)
        view.resetCursorRects()
        view.updateTrackingAreas()
    }

    private func apply(to view: DividerOverlayView) {
        view.dividerCenters = dividerCenters
        view.onDrag = onDrag
        view.onDoubleClick = onDoubleClick
    }
}

struct MainChildSplitDividerLine: View {
    var body: some View {
        Rectangle()
            .fill(ChildPaneMetrics.splitDividerColor)
            .frame(width: ChildPaneMetrics.columnDividerWidth)
            .allowsHitTesting(false)
            .accessibilityLabel(L("拖动调整分割比例"))
    }
}

