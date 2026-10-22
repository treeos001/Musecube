# Privacy / 隐私说明

Musecube collects no analytics, usage statistics or crash reports, and contains no tracking or advertising SDKs. We run no server that receives data about you.

## Network requests the app makes

- **Websites you open.** Each tool's page is loaded directly from that website. That site sees your IP address and whatever it normally sees from a browser, and its own privacy policy applies.
- **Tool icons.** Icons in the store and sidebar are downloaded directly from each tool's own website (no third-party favicon service). This happens even for tools you haven't opened, while you browse the store, so **those websites can see your IP address**.
- **Tool catalog updates.** The current version ships the catalog inside the app and does not download it. If remote catalog updates are added later, the app will contact our catalog server to fetch the list; that server will see your IP address. This document will be updated before that ships.
- **App updates.** When automatic updates are configured, Sparkle contacts the update server (appcast) to check for a new version; that server sees your IP address and the app version. In the current builds the update address is a placeholder, so no update request is made at all.
- **Fraudulent-site warnings** are provided by WebKit's built-in safe-browsing service, the same as in Safari.
- **Support link.** Help and About (“Buy a Coffee for Shukuinan”) open https://ko-fi.com/shukuinan in the system browser. That request is the browser's, not the app's. Musecube does not record the click and does not take payment inside the app.
- **Feedback.** Help, the store footer, and About open this repository's GitHub Issues page in the system browser. That request is the browser's. Musecube does not record the click.
- **Contact.** You can email shukuinan@musecube.app about privacy questions. This address receives mail only; it is not a support line and replies aren't guaranteed.

## Data stored on your Mac

Your tool list, sidebar icons, download history, settings and each site's sign-in data (cookies, local storage) are stored only on your Mac, inside the app's sandbox container. Sign-in data is kept in a separate store per site. Deleting a tool can also delete that site's data. Nothing is synced or uploaded by Musecube.

## Security measures (implemented)

- App Sandbox is enabled.
- Only HTTPS pages are loaded, except localhost. Other URL schemes are cancelled. A clicked `mailto:` link opens in the system mail client.
- Separate website data store per site.
- Downloaded files get the macOS quarantine flag. Installer downloads require confirmation. A file created by the page itself is not written until you confirm, unless you already chose "ask every time" (the save panel is that confirmation).
- One short script is injected into tool pages. It only turns `window.open` of a `blob:` or `data:` URL into a native download.
- A navigation to accounts.google.com is blocked. Choosing “Use in Browser” opens the tool in the default browser. That browser sign-in is not copied into the app.
- The sandboxed app does not get a temporary exception to read any other app's data folder.

---

## 中文

Musecube 不收集使用统计、不做崩溃上报，不含任何追踪或广告 SDK，我们没有接收你数据的服务器。中文名称灵感盒只作备注。

- **你打开的网站**：页面直接从对方网站加载，对方能看到你的 IP，适用对方自己的隐私政策。
- **工具图标**：商店和侧栏的图标直接从各工具网站加载（不用第三方图标服务）。浏览商店时，即使没打开该工具也会加载，所以**对方网站会看到你的 IP**。
- **目录更新**：当前版本目录内置在 App 里，不联网拉取。以后如果加上远程更新，App 会访问我们的目录服务器，服务器能看到你的 IP；上线前会先更新本说明。
- **App 更新**：配置好后，Sparkle 会访问更新服务器检查新版本，服务器能看到你的 IP 和版本号。目前更新地址还是占位值，不会发出任何更新请求。
- **诈骗网站警告**：使用 WebKit 自带的安全浏览服务，和 Safari 相同。
- **支持链接**：帮助菜单和关于窗口的「Buy a Coffee for Shukuinan」用系统浏览器打开 https://ko-fi.com/shukuinan。这次访问是浏览器发出的，Musecube 不记录点击，也不在 App 内收款。
- **反馈**：帮助菜单、商店底部和关于窗口用系统浏览器打开本仓库的 GitHub Issues。这次访问是浏览器发出的，Musecube 不记录点击。
- **联系**：隐私相关的问题可以发邮件到 shukuinan@musecube.app。这个地址只用于收信，不是客服渠道，不保证回复。
- **本地数据**：工具列表、图标、下载记录、设置和各网站登录信息只保存在你的 Mac 上的沙盒容器里，按网站分开存放，不会同步或上传。
- **已实现的安全措施**：App Sandbox；只允许 HTTPS（本机 http 除外）；每个网站单独的数据存储；下载文件加隔离标记，安装包下载需确认，网页自己生成的文件在写入前会再问一次；每个工具页面注入一段短脚本，只把 `blob:` / `data:` 的 `window.open` 转成本机下载；打开 `accounts.google.com` 会被拦住，选「在浏览器里使用」后到系统浏览器打开该工具，浏览器里的登录不会复制回 App；沙盒不再例外读取其他 App 的数据目录。
