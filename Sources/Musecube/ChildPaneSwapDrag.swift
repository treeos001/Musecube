import AppKit
import SwiftUI

/// AppKit press-drag for swapping a child page onto the main web area (replaces SwiftUI DragGesture).
final class ChildPaneSwapDragView: NSView {
    var childID: UUID?
    var onSwap: (() -> Void)?
    var onTapIfNoDrag: (() -> Void)?
    var onDragBegan: (() -> Void)?
    var onDragEnded: (() -> Void)?

    private var pressInWindow: NSPoint = .zero
    private var dragging = false
    private static let moveThreshold: CGFloat = 8

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override var isOpaque: Bool { false }
    override var focusRingType: NSFocusRingType {
        get { .none }
        set { }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func layout() {
        super.layout()
        if bounds.width < 1 || bounds.height < 1 {
            if let superview, superview.bounds.width > 0, superview.bounds.height > 0 {
                frame = superview.bounds
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard event.buttonNumber == 0 else {
            super.mouseDown(with: event)
            return
        }
        pressInWindow = event.locationInWindow
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard event.buttonNumber == 0 else { return }
        if !dragging {
            let loc = event.locationInWindow
            let dx = loc.x - pressInWindow.x
            let dy = loc.y - pressInWindow.y
            if hypot(dx, dy) < Self.moveThreshold { return }
            dragging = true
            onDragBegan?()
            if let id = childID {
                ChildPaneManager.shared.beginSwapDrag(childID: id) { [weak self] in
                    self?.onSwap?()
                }
            }
        }
        if dragging, let id = childID {
            ChildPaneManager.shared.updateDrag(id)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let wasDragging = dragging
        defer {
            dragging = false
            if wasDragging { onDragEnded?() }
        }
        guard event.buttonNumber == 0 else { return }
        if wasDragging, let id = childID {
            _ = ChildPaneManager.shared.completeSwapDrag(from: id)
        } else {
            onTapIfNoDrag?()
        }
    }
}

struct ChildPaneSwapDragSurface: NSViewRepresentable {
    let childID: UUID
    let onSwap: () -> Void
    var onTapIfNoDrag: (() -> Void)?
    var onDragBegan: (() -> Void)?
    var onDragEnded: (() -> Void)?

    func makeNSView(context: Context) -> ChildPaneSwapDragView {
        let view = ChildPaneSwapDragView()
        view.childID = childID
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        applyHandlers(to: view)
        return view
    }

    func updateNSView(_ view: ChildPaneSwapDragView, context: Context) {
        view.childID = childID
        applyHandlers(to: view)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ChildPaneSwapDragView, context: Context) -> CGSize? {
        let w = proposal.width ?? 0
        let h = proposal.height ?? 22
        let width = w > 0 ? w : 10_000
        return CGSize(width: width, height: max(h, 22))
    }

    private func applyHandlers(to view: ChildPaneSwapDragView) {
        view.onSwap = onSwap
        view.onTapIfNoDrag = onTapIfNoDrag
        view.onDragBegan = onDragBegan
        view.onDragEnded = onDragEnded
    }
}

/// Registers the main web drop zone with `ChildPaneManager` for AppKit screen hit-testing.
struct MainWebDropZoneHost: NSViewRepresentable {
    func makeNSView(context: Context) -> MainWebDropZoneHostView {
        MainWebDropZoneHostView()
    }

    func updateNSView(_ view: MainWebDropZoneHostView, context: Context) {}
}

final class MainWebDropZoneHostView: NSView {
    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        ChildPaneManager.shared.mainDropHostView = self
    }

    override func removeFromSuperview() {
        if ChildPaneManager.shared.mainDropHostView === self {
            ChildPaneManager.shared.mainDropHostView = nil
        }
        super.removeFromSuperview()
    }

    override func layout() {
        super.layout()
        ChildPaneManager.shared.noteMainDropZoneLayoutChanged()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        ChildPaneManager.shared.noteMainDropZoneLayoutChanged()
    }
}
