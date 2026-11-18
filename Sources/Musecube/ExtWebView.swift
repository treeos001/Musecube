import AppKit
import WebKit

private let openLinkInNewWindowID = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierOpenLinkInNewWindow")
private let openImageInNewWindowID = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierOpenImageInNewWindow")

final class ExtWebView: WKWebView {
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        let title = L("在新窗口打开")
        var foundDockItem = false
        for item in menu.items {
            guard let id = item.identifier else { continue }
            if id == openLinkInNewWindowID || id == openImageInNewWindowID {
                item.title = title
                foundDockItem = true
            }
        }
        if let wc = uiDelegate as? WebController {
            if foundDockItem {
                wc.armContextMenuDock(for: self, menu: menu)
            } else if let url = wc.contextMenuURL(for: self) {
                let custom = NSMenuItem(title: title, action: #selector(extOpenInDockedChild(_:)), keyEquivalent: "")
                custom.target = self
                custom.representedObject = url
                custom.identifier = openLinkInNewWindowID
                let insertAt = menu.items.firstIndex(where: { $0.identifier == .init("WKMenuItemIdentifierOpenLink") }) ?? 0
                menu.insertItem(custom, at: min(insertAt + 1, menu.items.count))
                wc.armContextMenuDock(for: self, menu: menu)
            }
        }
    }

    @objc private func extOpenInDockedChild(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        (uiDelegate as? WebController)?.openURLInDockedChild(url, from: self)
    }
}