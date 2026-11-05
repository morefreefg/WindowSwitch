import SwiftUI
import AppKit
import CoreGraphics
import Darwin

@MainActor
struct ApplicationActionsMenu: View {
    let bundleID: String
    var onStatus: (String) -> Void = { _ in }
    var onAction: () -> Void = {}

    @State private var bookmarkResult: BookmarkMenuResult?
    @State private var bookmarkLoading = false
    @State private var bookmarkRequest = UUID()
    @State private var mailboxes: [MailboxMenuEntry] = []
    @State private var mailMessage: String?
    @State private var scriptRunning = false

    var body: some View {
        Group {
            if let browser = BrowserBookmarkSource.source(for: bundleID) {
                Menu(browser.isSafari ? "常用站点" : "书签栏") {
                    if bookmarkLoading { Text("正在读取…") }
                    if let result = bookmarkResult {
                        ForEach(result.items) { bookmark in
                            Button(bookmark.title) { openBookmark(bookmark) }
                        }
                        if let message = result.message { Text(message) }
                    }
                    Button(bookmarkResult == nil ? "加载书签…" : "重新读取") { loadBookmarks(force: true) }
                        .disabled(bookmarkLoading)
                }
                .task(id: bundleID) { await fetchBookmarks(force: false) }
            }
            if ["com.apple.Music", "com.apple.iTunes"].contains(bundleID) {
                Menu("播放控制") {
                    Button("播放 / 暂停") { runMediaCommand("playpause") }
                    Button("上一首") { runMediaCommand("previous track") }
                    Button("下一首") { runMediaCommand("next track") }
                }
                .disabled(scriptRunning)
            }
            if bundleID == "com.apple.mail" {
                Button("写邮件…") {
                    onAction()
                    if let url = URL(string: "mailto:") { NSWorkspace.shared.open(url) }
                }
                Menu("收件箱与未读数") {
                    ForEach(mailboxes) { box in
                        Text("\(box.account) · \(box.name)（\(box.unread)）")
                    }
                    if let mailMessage { Text(mailMessage) }
                    Button(scriptRunning ? "正在读取…" : "加载收件箱…") { loadMailboxes() }
                        .disabled(scriptRunning)
                }
            }
            if ["com.apple.iCal", "com.apple.Calendar"].contains(bundleID) {
                Button("新建日程…") { openNewWindow() }
            }
            if bundleID == "com.evernote.Evernote" {
                Button("新窗口…") { openNewWindow() }
            }
        }
    }

    private func loadBookmarks(force: Bool) {
        Task { await fetchBookmarks(force: force) }
    }

    private func fetchBookmarks(force: Bool) async {
        let request = UUID()
        bookmarkRequest = request
        bookmarkLoading = true
        let result = await ApplicationBookmarksStore.shared.load(bundleID: bundleID, force: force)
        guard !Task.isCancelled, bookmarkRequest == request else { return }
        bookmarkResult = result
        bookmarkLoading = false
        if force { onStatus(result.message ?? "已读取 \(result.items.count) 个书签") }
    }

    private func openBookmark(_ bookmark: ApplicationBookmark) {
        onAction()
        guard bookmark.url.scheme?.lowercased() != "javascript" else { return }
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            onStatus("未找到对应浏览器")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([bookmark.url], withApplicationAt: appURL, configuration: configuration) { _, error in
            if let error {
                let message = error.localizedDescription
                Task { @MainActor in onStatus("打开书签失败：\(message)") }
            }
        }
    }

    private func runMediaCommand(_ command: String) {
        guard !scriptRunning, ["playpause", "previous track", "next track"].contains(command),
              ["com.apple.Music", "com.apple.iTunes"].contains(bundleID) else { return }
        onAction()
        runScript("tell application id \"\(bundleID)\" to \(command)") { result in
            switch result {
            case .success: onStatus("已发送播放控制")
            case .failure(let message): onStatus(message)
            }
        }
    }

    private func loadMailboxes() {
        guard !scriptRunning else { return }
        onAction()
        // This is deliberately reached only from the explicit "Load inboxes" button.
        // It reads mailbox names and counts, never messages or message bodies.
        let script = #"""
        on cleaned(value)
            set oldDelimiters to AppleScript's text item delimiters
            set AppleScript's text item delimiters to {tab, linefeed, return}
            set pieces to text items of (value as text)
            set AppleScript's text item delimiters to " "
            set resultText to pieces as text
            set AppleScript's text item delimiters to oldDelimiters
            return resultText
        end cleaned
        tell application id "com.apple.mail"
            set inboxes to {}
            try
                set inboxes to mailboxes of inbox
            end try
            if (count inboxes) is 0 then
                repeat with acc in accounts
                    repeat with box in mailboxes of acc
                        set boxName to name of box
                        if boxName is "INBOX" or boxName is "Inbox" or boxName is "收件箱" then
                            set end of inboxes to box
                        end if
                        if (count inboxes) ≥ 100 then exit repeat
                    end repeat
                    if (count inboxes) ≥ 100 then exit repeat
                end repeat
            end if
            set rows to {}
            repeat with box in inboxes
                set accountName to "Mail"
                try
                    set accountName to name of account of box
                end try
                set end of rows to ((my cleaned(accountName)) & tab & (my cleaned(name of box)) & tab & (unread count of box as text))
                if (count rows) ≥ 100 then exit repeat
            end repeat
        end tell
        set AppleScript's text item delimiters to linefeed
        return rows as text
        """#
        runScript(script) { result in
            switch result {
            case .success(let output):
                mailboxes = output.split(separator: "\n").prefix(100).enumerated().compactMap { offset, line in
                    let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                    guard fields.count == 3, let unread = Int(fields[2]) else { return nil }
                    return MailboxMenuEntry(id: offset, account: String(fields[0]), name: String(fields[1]), unread: unread)
                }
                mailMessage = mailboxes.isEmpty ? "未找到可读取的收件箱" : nil
                ApplicationActionResults.showMailboxes(mailboxes, message: mailMessage)
                onStatus(mailMessage ?? "已读取 \(mailboxes.count) 个收件箱的未读数")
            case .failure(let message):
                mailMessage = message
                ApplicationActionResults.showMailboxes([], message: message)
                onStatus(message)
            }
        }
    }

    private func runScript(_ script: String, completion: @escaping (ApplicationScriptResult) -> Void) {
        scriptRunning = true
        Task {
            let result = await ApplicationMenuScripts.run(script)
            scriptRunning = false
            completion(result)
        }
    }

    private func openNewWindow() {
        onAction()
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            onStatus("未找到应用")
            return
        }
        Task {
            do {
                let app = try await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                let down = CGEvent(keyboardEventSource: nil, virtualKey: 45, keyDown: true)
                let up = CGEvent(keyboardEventSource: nil, virtualKey: 45, keyDown: false)
                down?.flags = .maskCommand
                up?.flags = .maskCommand
                // Matches WindowService.syntheticEventMarker so our own event tap passes these events through.
                down?.setIntegerValueField(.eventSourceUserData, value: 0x5753_4B45_59)
                up?.setIntegerValueField(.eventSourceUserData, value: 0x5753_4B45_59)
                down?.postToPid(app.processIdentifier)
                up?.postToPid(app.processIdentifier)
                onStatus("已打开新建窗口；请在应用中完成编辑")
            } catch { onStatus("打开应用失败：\(error.localizedDescription)") }
        }
    }
}

private nonisolated struct ApplicationBookmark: Identifiable, Sendable {
    let title: String
    let url: URL
    var id: String { url.absoluteString }
}

private nonisolated struct BookmarkMenuResult: Sendable {
    let items: [ApplicationBookmark]
    let message: String?
}

private nonisolated struct MailboxMenuEntry: Identifiable, Sendable {
    let id: Int
    let account: String
    let name: String
    let unread: Int
}

private nonisolated struct BrowserBookmarkSource: Sendable {
    let relativePath: String
    let isSafari: Bool

    static func source(for bundleID: String) -> BrowserBookmarkSource? {
        let folders = [
            "com.google.Chrome": "Google/Chrome", "com.google.Chrome.canary": "Google/Chrome Canary",
            "org.chromium.Chromium": "Chromium", "com.microsoft.edgemac": "Microsoft Edge",
            "com.microsoft.edgemac.Beta": "Microsoft Edge Beta", "com.microsoft.edgemac.Dev": "Microsoft Edge Dev",
            "com.brave.Browser": "BraveSoftware/Brave-Browser", "com.brave.Browser.beta": "BraveSoftware/Brave-Browser-Beta",
            "com.vivaldi.Vivaldi": "Vivaldi", "company.thebrowser.Browser": "Arc/User Data",
            "com.operasoftware.Opera": "com.operasoftware.Opera", "com.operasoftware.OperaGX": "com.operasoftware.OperaGX"
        ]
        if ["com.apple.Safari", "com.apple.SafariTechnologyPreview"].contains(bundleID) {
            return BrowserBookmarkSource(relativePath: "Library/Safari/TopSites.plist", isSafari: true)
        }
        guard let folder = folders[bundleID] else { return nil }
        return BrowserBookmarkSource(relativePath: "Library/Application Support/\(folder)/Default/Bookmarks", isSafari: false)
    }
}

private actor ApplicationBookmarksStore {
    static let shared = ApplicationBookmarksStore()
    // A single cache entry bounds the total retained bookmark count to 100.
    private var cache: (bundleID: String, date: Date, result: BookmarkMenuResult)?

    func load(bundleID: String, force: Bool) -> BookmarkMenuResult {
        if !force, let cache, cache.bundleID == bundleID, Date().timeIntervalSince(cache.date) < 60 { return cache.result }
        let result = read(bundleID: bundleID)
        cache = (bundleID, Date(), result)
        return result
    }

    private func read(bundleID: String) -> BookmarkMenuResult {
        guard let source = BrowserBookmarkSource.source(for: bundleID) else {
            return BookmarkMenuResult(items: [], message: "此应用没有书签菜单")
        }
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(source.relativePath)
        do {
            let metadata = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = metadata[.size] as? NSNumber, size.int64Value <= 4 * 1024 * 1024 else {
                return BookmarkMenuResult(items: [], message: "书签文件超过4MB，未自动读取")
            }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count <= 4 * 1024 * 1024 else {
                return BookmarkMenuResult(items: [], message: "书签文件超过4MB，未自动读取")
            }
            var items: [ApplicationBookmark] = []
            if source.isSafari {
                guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      let sites = plist["TopSites"] as? [[String: Any]] else {
                    return BookmarkMenuResult(items: [], message: "未找到旧版 Safari 常用站点数据")
                }
                for site in sites.prefix(10) {
                    if let raw = site["TopSiteURLString"] as? String,
                       let bookmark = bookmark(title: site["TopSiteTitle"] as? String, rawURL: raw) { items.append(bookmark) }
                }
            } else {
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let roots = json["roots"] as? [String: Any],
                      let bar = roots["bookmark_bar"] as? [String: Any] else {
                    return BookmarkMenuResult(items: [], message: "书签栏数据格式无法识别")
                }
                var visited = 0
                func visit(_ node: [String: Any], depth: Int) {
                    guard items.count < 100, depth <= 12, visited < 10_000 else { return }
                    visited += 1
                    if let raw = node["url"] as? String,
                       let bookmark = bookmark(title: node["name"] as? String, rawURL: raw) { items.append(bookmark) }
                    if let children = node["children"] as? [[String: Any]] {
                        for child in children {
                            visit(child, depth: depth + 1)
                            if items.count >= 100 || visited >= 10_000 { break }
                        }
                    }
                }
                visit(bar, depth: 0)
            }
            var seen: Set<String> = []
            items = items.filter { seen.insert($0.id).inserted }
            return BookmarkMenuResult(items: items, message: items.isEmpty ? "书签栏为空或没有可打开的链接" : nil)
        } catch {
            let code = (error as NSError).code
            let message: String
            if [NSFileReadNoPermissionError, 1, 13].contains(code) {
                message = "没有读取权限，请在系统设置允许访问相应浏览器数据"
            } else if code == NSFileReadNoSuchFileError || code == 2 {
                message = source.isSafari ? "没有旧版 Safari 常用站点文件" : "未找到 Default 配置的书签文件"
            } else { message = "读取失败：\(error.localizedDescription)" }
            return BookmarkMenuResult(items: [], message: message)
        }
    }

    private func bookmark(title: String?, rawURL: String) -> ApplicationBookmark? {
        let raw = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              !["javascript", "data", "vbscript"].contains(scheme) else { return nil }
        let name = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayTitle = ((name?.isEmpty == false ? name : nil) ?? url.absoluteString)
            .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        return ApplicationBookmark(title: String(displayTitle.prefix(160)), url: url)
    }
}

private nonisolated enum ApplicationScriptResult: Sendable {
    case success(String)
    case failure(String)
}

private nonisolated enum ApplicationMenuScripts {
    static func run(_ script: String) async -> ApplicationScriptResult {
        await Task.detached(priority: .utility) { runSynchronously(script) }.value
    }

    private static func runSynchronously(_ script: String) -> ApplicationScriptResult {
        let directory = URL(fileURLWithPath: "/tmp/codex-windowswitch-actions-\(UUID().uuidString)", isDirectory: true)
        let outputURL = directory.appendingPathComponent("stdout")
        let errorURL = directory.appendingPathComponent("stderr")
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? manager.removeItem(at: directory) }
            guard manager.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600]),
                  manager.createFile(atPath: errorURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                return .failure("无法创建临时输出文件")
            }
            let output = try FileHandle(forWritingTo: outputURL)
            let error = try FileHandle(forWritingTo: errorURL)
            defer { try? output.close(); try? error.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            process.standardOutput = output
            process.standardError = error
            let finished = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in finished.signal() }
            try process.run()
            if finished.wait(timeout: .now() + 8) == .timedOut {
                process.terminate()
                if finished.wait(timeout: .now() + 0.2) == .timedOut {
                    _ = Darwin.kill(process.processIdentifier, SIGKILL)
                    _ = finished.wait(timeout: .now() + 0.3)
                }
                return .failure("操作超过8秒，已停止；可能需要允许自动化访问")
            }
            func readBounded(_ url: URL) -> String {
                guard let input = try? FileHandle(forReadingFrom: url) else { return "" }
                defer { try? input.close() }
                let data = (try? input.read(upToCount: 65_536)) ?? Data()
                return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if process.terminationStatus == 0 { return .success(readBounded(outputURL)) }
            let message = readBounded(errorURL)
            return .failure(message.isEmpty ? "应用拒绝了自动化操作" : "自动化未完成：\(message.prefix(400))")
        } catch { return .failure("无法执行应用操作：\(error.localizedDescription)") }
    }
}


/// A separate result panel survives the switcher overlay closing after a user action.
@MainActor
private enum ApplicationActionResults {
    private static var mailboxPanel: NSPanel?

    static func showMailboxes(_ entries: [MailboxMenuEntry], message: String?) {
        let panel: NSPanel
        if let existing = mailboxPanel { panel = existing }
        else {
            panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            panel.title = "收件箱与未读数"
            panel.isReleasedWhenClosed = false
            panel.minSize = NSSize(width: 440, height: 260)
            mailboxPanel = panel
        }
        panel.contentView = NSHostingView(rootView: VStack(alignment: .leading, spacing: 12) {
            Text("收件箱与未读数").font(.headline)
            if let message { Text(message).foregroundStyle(.secondary).textSelection(.enabled) }
            if !entries.isEmpty {
                List(entries) { entry in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(entry.account).font(.caption).foregroundStyle(.secondary)
                            Text(entry.name)
                        }
                        Spacer()
                        Text(String(entry.unread)).monospacedDigit()
                    }
                }
            }
            HStack {
                Text("仅显示邮箱名称和未读数量").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("关闭") { panel.close() }.keyboardShortcut(.cancelAction)
            }
        }.padding(18).frame(minWidth: 440, minHeight: 260))
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
