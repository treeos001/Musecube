import AppKit
import ChildPaneColorKit

enum ToolWindowSizeStore {
  private static let prefix = "toolWindowFrame."

  static func load(for toolID: UUID) -> CGSize? {
    let w = UserDefaults.standard.double(forKey: prefix + toolID.uuidString + ".w")
    let h = UserDefaults.standard.double(forKey: prefix + toolID.uuidString + ".h")
    guard w >= 480, h >= 360 else { return nil }
    return CGSize(width: w, height: h)
  }

  static func save(_ size: CGSize, for toolID: UUID) {
    UserDefaults.standard.set(Double(size.width), forKey: prefix + toolID.uuidString + ".w")
    UserDefaults.standard.set(Double(size.height), forKey: prefix + toolID.uuidString + ".h")
  }
}

final class ToolWindowFrameCoordinator {
  static let shared = ToolWindowFrameCoordinator()

  private weak var window: NSWindow?
  private var resizeObs: [NSObjectProtocol] = []
  private var resizeDebounce: DispatchWorkItem?
  private(set) var suppressSizePersistence = false
  private(set) var isAnimatingToolSwitch = false

  private init() {}

  func attach(to window: NSWindow) {
    self.window = window
    let nc = NotificationCenter.default
    resizeObs.forEach { nc.removeObserver($0) }
    resizeObs.removeAll()
    resizeObs.append(nc.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
      self?.scheduleDebouncedSave()
    })
    resizeObs.append(nc.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: window, queue: .main) { [weak self] _ in
      self?.saveCurrentToolSizeIfNeeded()
    })
  }

  func defaultFrameSize(for window: NSWindow, visibleFrame: CGRect) -> CGSize {
    let content = ToolWindowSizing.defaultContentSize(visibleFrame: visibleFrame)
    let contentRect = NSRect(origin: .zero, size: content)
    return window.frameRect(forContentRect: contentRect).size
  }

  func saveSize(for toolID: UUID, from window: NSWindow) {
    guard !suppressSizePersistence else { return }
    ToolWindowSizeStore.save(window.frame.size, for: toolID)
  }

  func saveCurrentToolSizeIfNeeded() {
    guard let window, let tid = ChildPaneManager.shared.currentToolID else { return }
    saveSize(for: tid, from: window)
  }

  private func scheduleDebouncedSave() {
    resizeDebounce?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.saveCurrentToolSizeIfNeeded() }
    resizeDebounce = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
  }

  func handleToolSwitch(from previousID: UUID?, to newID: UUID?) {
    guard let window, let newID else { return }
    if let previousID, previousID != newID {
      saveSize(for: previousID, from: window)
    }
    if window.styleMask.contains(.fullScreen) {
      ChildPaneManager.shared.finishToolWindowTransition()
      return
    }
    applyTargetFrame(for: newID, animated: shouldAnimate(window: window))
  }

  private func shouldAnimate(window: NSWindow) -> Bool {
    !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  }

  func applyTargetFrame(for toolID: UUID, animated: Bool) {
    guard let window else { return }
    let screen = window.screen ?? NSScreen.main
    let visible = screen?.visibleFrame ?? .zero
    let defaultSize = defaultFrameSize(for: window, visibleFrame: visible)
    let stored = ToolWindowSizeStore.load(for: toolID)
    let current = window.frame
    let result = ToolWindowSizing.targetFrame(
      current: current,
      stored: stored,
      defaultSize: defaultSize,
      visibleFrame: visible,
      minSize: window.minSize
    )
    guard !result.unchanged else {
      ChildPaneManager.shared.finishToolWindowTransition()
      return
    }
    let target = result.frame

    if animated {
      isAnimatingToolSwitch = true
      suppressSizePersistence = true
      NSAnimationContext.runAnimationGroup({ ctx in
        ctx.duration = 0.3
        ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        ctx.allowsImplicitAnimation = true
        window.animator().setFrame(target, display: true)
      }, completionHandler: { [weak self] in
        self?.isAnimatingToolSwitch = false
        self?.suppressSizePersistence = false
        ChildPaneManager.shared.finishToolWindowTransition()
      })
    } else {
      suppressSizePersistence = true
      window.setFrame(target, display: true, animate: false)
      suppressSizePersistence = false
      ChildPaneManager.shared.finishToolWindowTransition()
    }
  }

  func noteProgrammaticFrameChange(saveFor toolID: UUID?) {
    guard let window, let toolID, !suppressSizePersistence, !isAnimatingToolSwitch else { return }
    saveSize(for: toolID, from: window)
  }

  func performProgrammaticFrame(_ block: () -> Void, saveFor toolID: UUID?) {
    suppressSizePersistence = true
    block()
    suppressSizePersistence = false
    noteProgrammaticFrameChange(saveFor: toolID)
  }
}