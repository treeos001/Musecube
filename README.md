# Musecube

Musecube is a native macOS app (SwiftUI + WKWebView, using the system WebKit engine) that keeps the web tools you use every day — translators, image compressors, converters, developer utilities — in one window. Tools sit in a narrow sidebar; the selected tool fills the rest of the window, with no address bar or tabs.

Chinese name: 灵感盒. This name is a note only. The app shows Musecube in every language, including the Chinese menus, window title, and Dock.

## Why Musecube

I'm a designer and illustrator. I use a few excellent web tools at work, and I didn't want to hunt for them among browser tabs. So I made Musecube. Open it, and they're ready.

Musecube is free and open source. If it helps you, you can [buy the author a coffee ☕](https://ko-fi.com/shukuinan).

> 我是设计师和插画师。工作里常要用一些很棒的网页工具，不想每次都在浏览器的标签页里翻找，所以做了 Musecube，打开就能用。
>
> Musecube 完全免费、开源。如果它帮到了你，欢迎请作者喝杯咖啡 ☕

## Features

- Sidebar of tools. Add them from the built-in store, or paste any HTTPS URL from the dashed “Add” button under the sidebar list or the first card in the store’s “My additions”. Right-click a tool icon for **Reload** (localized **重新载入**) to refresh that tool’s page; if its page was unloaded from memory, it loads again. The View menu’s **Reload** item is ⌘R for the selected tool. Tool icons default to 42pt in 64pt-tall rows; as you add more tools, row height and icon size shrink together (down to 25.2pt icons / 38.4pt rows, never below 24pt icons) so the list fits the space above the fixed Add / store / About controls, then scrolls vertically like before.
- **Per-tool window size.** Each tool remembers its main window frame size (after resize or child-pane auto-grow). Switching tools animates the window (about 0.3s, ease-in-ease-out, top-left fixed) to that tool’s size, or to the default content-based size (min of 1000×700 pt and 85% of the screen’s visible area) if none is saved. Full Screen and Reduce Motion skip the animation. Stored in UserDefaults per tool ID. Upgrading from older builds no longer restores the legacy global `WebToolboxMain` window position—only per-tool saved sizes apply.
- **Child page docking.** When a website opens a new window (like a chat session in DeepSeek), or you right-click a link or image and choose **Open in New Window** (localized **在新窗口打开**), it appears in a resizable right pane instead of floating independently—**only** while that context-menu path is armed (~10s); ordinary `window.open` popups still follow size rules and may float. Several children can stay **expanded side by side** to the right of the main page (only ones you collapse become colored “folder ear” tabs—**outside** the right edge in normal mode, **inside** the content’s right edge in Full Screen unless you turn on **Hide tabs in full screen** in Settings); clicking an ear tab re-expands that page without collapsing the others. Column dividers ±4pt on 1pt rules; manual pair minimums about 240pt main / 200pt child; default compression about 360pt / 260pt; the app never auto-collapses an expanded child—it shrinks, then grows the window within the screen, then scrolls horizontally. When a background tool page is LRU-evicted under memory pressure, its docked children are torn down too (current tool is never evicted). Six stable palette colors per tool; drag any child title bar or a collapsed tab onto the main area to swap positions. Authentication and payment windows stay floating to preserve their callbacks.
- The store lists every entry. Category chips and search can be combined. Tapping a card opens a web preview. Each card has one button, “+ Add” or “Remove”. Remove asks for confirmation and, when no other tool shares that site, clears its sign-in data. Several jobs on one website are separate entries.
- Sign-in data is kept per site: entries on the same site share one sign-in; different sites are isolated from each other. Sign-ins persist across restarts.
- Global shortcut ⌥M for quick open; menu-bar icon; optional "keep running after the window is closed"; optional Dock icon; optional launch at login.
- Downloads are marked with the macOS quarantine flag. Installer files ask for confirmation first. A page that generates a file (rather than a normal link) must also ask before anything is written.
- Warning page for known fraudulent sites (WebKit's built-in safe browsing).
- A page that goes to accounts.google.com is blocked. The dialog button “Use in Browser” opens that tool in the default browser. A Google sign-in completed in the browser is not copied back into the app. Email, Apple, and GitHub sign-in stay inside the app.
- Automatic updates via Sparkle stay off until a real update address is set.
- About is in the sidebar and the Musecube menu. The window shows a centered icon, name, and version, then two left-aligned paragraphs (why it was made, then free and open source), a trademark line, then “Buy a Coffee for Shukuinan” and “Feedback”. The Chinese product name is not in the window.
- Help and About open https://ko-fi.com/shukuinan in the system browser. The app does not record the click.

## Privacy

- No analytics, no usage statistics, no tracking, no advertising IDs.
- Musecube does not inject ads into third-party pages and does not import cookies from your browsers. One small script is injected so a page can hand a generated file to the download list; saving still asks you first.
- Only HTTPS pages are opened. App Sandbox is enabled. The User-Agent is WebKit's default plus an honest `Musecube/<version>` suffix; we do not impersonate other browsers.

See [PRIVACY.md](PRIVACY.md) for exactly what network requests the app makes.

## Build from source

Requirements: macOS 14+, Xcode or the Command Line Tools (Swift 5.9+).

```bash
./build_app.sh             # -> build/Musecube.app
open build/Musecube.app
```

`./build_app.sh` without `SIGN_IDENTITY` produces an ad-hoc signature. Do not distribute that build. A shareable build is signed, notarized, and stapled. See [RELEASING.md](RELEASING.md).

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./build_app.sh
```

The entitlements include `com.apple.security.cs.allow-jit` so WKWebView can run JavaScript under the hardened runtime.

## Tool catalog

The store lists every entry in `Resources/tool_catalog.json`. Each job is its own entry, including several jobs on the same website, so the listing is the tool rather than that site's homepage. Read-only reference tables stay in the catalog. Descriptions are written by us. Icons are loaded at runtime from each tool's own website and are not bundled. A listing is not a security review of that site. PairDrop is not included.

### Suggest a tool / request removal

Open an issue on this repository's GitHub Issues. The Help menu, the store footer, and About each have a “Feedback” button. It opens in the system browser. The app does not record the click. Site owners who want their tool removed from the catalog can ask there, and we will remove it.

## Trademarks

All tool names, logos and trademarks belong to their respective owners. Musecube is not affiliated with, endorsed by, or sponsored by any of the listed services.

## License

[MIT](LICENSE).

---

## 中文简介

Musecube 是一个原生 macOS 网页工具箱：把常用的网页工具收进同一个窗口，左侧侧边栏放工具，右侧打开当前工具，没有地址栏和标签页。中文名称灵感盒只作备注，界面、菜单和 Dock 都显示 Musecube。

- **商店**：列出目录里的全部工具。分类胶囊可以和搜索一起用。点卡片进入网页预览。卡片上只有「＋ 添加」或「取消」；取消前会确认，没有别的工具共用该站点时会清掉该站登录数据。
- **按工具记忆窗口尺寸**：每个工具单独记住主窗口外框尺寸（用户拖改结束或子页触发自动加宽时写入）。切换工具时，窗口以约 0.3 秒、ease-in-ease-out 动画回到该工具上次尺寸；若无记录则用默认内容尺寸（与首次启动相同：内容区取 1000×700 pt 与当前屏可见区域 85% 的较小值，再换算为窗口外框）。动画固定左上角，并限制在当前屏可见范围内。全屏与「减少动态效果」时不播动画。尺寸按工具 ID 存在 UserDefaults。
- **子页面停靠**：右键「在新窗口打开」在约 **10 秒**就绪期内停靠到右侧分栏；普通 `window.open` 仍按尺寸规则，小窗可继续浮动。网站其它新窗口（如 DeepSeek 对话）进入右侧可调整面板。同一工具可多列同时展开；仅主动收起的子页变为耳形彩色标签（窗口模式下贴在右缘**外侧**，全屏时默认贴在内容区右缘**内侧**；设置里可开启「全屏时隐藏标签」）。升级用户不再恢复旧版全局 `WebToolboxMain` 窗口位置，仅按工具记忆尺寸。收起标签纵向等高；主区与子页列、列与列之间 1pt 分隔线，分隔条 ±4pt 命中区拖动相邻两列（最小约 240pt/200pt，默认压缩约 360pt/260pt），**不会**自动收起已展开子页，先缩列、再加窗、再横向滚动。后台工具主页面因内存压力被 LRU 回收时，其停靠子页一并释放（当前工具不回收）。拖动标题栏或耳标签到主区可交换主次。认证和支付窗口保持浮动。
- **侧边栏图标**：默认 42pt 图标、64pt 行高；工具变多时，在「＋ 添加」/商店/关于等固定底栏之上的列表区域内，行高与图标按同一比例缩小（最小约 25.2pt 图标、38.4pt 行高，图标不低于 24pt），尽量一屏放下；到最小尺寸后列表纵向滚动，与原先一致。右键菜单首项为「重新载入」（英文 Reload），可刷新该工具页面；若页面已被 LRU 回收则重新加载。「显示」菜单的「重新载入」为 ⌘R，作用于当前选中的工具。
- **自己的网址**：从侧边栏底部的「＋ 添加」，或商店「我添加的」第一张卡片，粘贴任意 HTTPS 网址。同一网站的不同功能各占一条。
- **其他**：登录按网站分开保存，同一网站共用。⌥M 快速打开。有菜单栏图标。关窗口后可在后台运行，也可开机自动启动。更新地址填上之前，Sparkle 不会检查更新。Google 登录弹窗的按钮是「在浏览器里使用」，到系统浏览器打开该工具，浏览器里的登录不会回到 App。
- **隐私**：不追踪、不统计；不向第三方网页注入广告，不导入浏览器 cookie。页面里会注入一段很短的脚本，用来把网页生成的文件交给下载列表，保存前会再问一次。详见 [PRIVACY.md](PRIVACY.md)。
- **关于**：侧边栏和 Musecube 菜单都有。窗口里是图标、名称和版本，然后两段左对齐正文（创作背景，免费开源和请咖啡），再是商标说明，然后是 “Buy a Coffee for Shukuinan” 和「反馈」。界面不写灵感盒。打赏打开 https://ko-fi.com/shukuinan，反馈打开本仓库的 GitHub Issues，都走系统浏览器，App 不记录点击。构建命令是 `./build_app.sh`。
- **工具目录**：描述由我们自己撰写。收录不等于安全审计。PairDrop 未收录。推荐新工具或申请下架，请在 GitHub Issues 提交。
- **商标声明**：所列工具名称、图标与商标归各自所有者所有，与本产品无隶属、合作或背书关系。

## Support

I'm a designer and illustrator. I use a few excellent web tools at work, and I didn't want to hunt for them among browser tabs. So I made Musecube. Open it, and they're ready.

Musecube is free and open source. If it helps you, you can buy the author a coffee ☕

[https://ko-fi.com/shukuinan](https://ko-fi.com/shukuinan)

我是设计师和插画师。工作里常要用一些很棒的网页工具，不想每次都在浏览器的标签页里翻找，所以做了 Musecube，打开就能用。

Musecube 完全免费、开源。如果它帮到了你，欢迎请作者喝杯咖啡 ☕

## Contact

Email: shukuinan@musecube.app (receive-only; replies aren't guaranteed). For bugs and feature requests, please use GitHub Issues.

邮箱：shukuinan@musecube.app（只用于收信，不保证回复）。问题反馈和功能建议请走 GitHub Issues。
