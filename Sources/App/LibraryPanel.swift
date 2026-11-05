import AppKit
import SwiftUI

nonisolated struct LibraryEntry: Identifiable, Sendable {
    var id: String { url.path }
    let url: URL
    let name: String
    let subtitle: String
}

nonisolated struct LibraryResult: Sendable {
    let items: [LibraryEntry]
    let note: String
}

actor LibraryIndex {
    static let shared = LibraryIndex()
    func recentDocuments(bundleID: String?) -> LibraryResult {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let base = home.appendingPathComponent("Library/Application Support/com.apple.sharedfilelist")
        let stem: URL
        if let bundleID {
            stem = base.appendingPathComponent("com.apple.LSSharedFileList.ApplicationRecentDocuments")
                .appendingPathComponent(bundleID.lowercased())
        } else { stem = base.appendingPathComponent("com.apple.LSSharedFileList.RecentDocuments") }
        var sources = [stem.appendingPathExtension("sfl3"), stem.appendingPathExtension("sfl2")]
        if bundleID == nil { sources.append(home.appendingPathComponent("Library/Preferences/com.apple.recentitems.plist")) }
        var urls: [URL] = []
        var readAny = false
        for path in sources {
            guard let data = try? Data(contentsOf: path), data.count <= 8_000_000,
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) else { continue }
            readAny = true
            var visited = 0
            collectBookmarks(plist, urls: &urls, visited: &visited)
        }
        var seen: Set<String> = []
        let entries = urls.filter { $0.isFileURL && $0.pathExtension.lowercased() != "app"
            && FileManager.default.fileExists(atPath: $0.path) && seen.insert($0.path).inserted }
            .prefix(bundleID == nil ? 30 : 10).map {
                LibraryEntry(url: $0, name: $0.lastPathComponent, subtitle: $0.deletingLastPathComponent().path)
            }
        return LibraryResult(items: Array(entries), note: readAny ? "" : "系统最近文档列表暂不可读，可将文件拖到此面板打开。")
    }

    private func collectBookmarks(_ object: Any, urls: inout [URL], visited: inout Int) {
        guard visited < 10_000, urls.count < 200 else { return }
        visited += 1
        if let bookmark = object as? Data {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                  relativeTo: nil, bookmarkDataIsStale: &stale) { urls.append(url) }
        } else if let dictionary = object as? [String: Any] {
            // Direct SFL item order is preserved; keyed archive objects are traversed in archive order.
            if let items = dictionary["items"] ?? dictionary["Items"] {
                collectBookmarks(items, urls: &urls, visited: &visited)
            } else if let objects = dictionary["$objects"] {
                collectBookmarks(objects, urls: &urls, visited: &visited)
            } else {
                for key in dictionary.keys.sorted() {
                    if let child = dictionary[key] { collectBookmarks(child, urls: &urls, visited: &visited) }
                }
            }
        } else if let array = object as? [Any] {
            for item in array { collectBookmarks(item, urls: &urls, visited: &visited) }
        }
    }
}

@Observable private final class LibraryModel {
    var items: [LibraryEntry] = []
    var search = ""
    var note = ""
    var loading = true
    var selected: String?
    var filtered: [LibraryEntry] {
        search.isEmpty ? items : items.filter { "\($0.name) \($0.subtitle)".localizedStandardContains(search) }
    }
}

final class LibraryPanelController {
    private let index = LibraryIndex()
    private var window: NSWindow?
    private var work: Task<Void, Never>?
    func showDocuments(bundleID: String? = nil) {
        work?.cancel(); window?.close()
        let model = LibraryModel()
        let title = "最近文档"
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 650, height: 520),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = title; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: LibraryView(model: model, title: title, open: { [weak window] entry in
            NSWorkspace.shared.open(entry.url); window?.close()
        }))
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        self.window = window
        work = Task {
            let result = await index.recentDocuments(bundleID: bundleID)
            guard !Task.isCancelled else { return }
            model.items = result.items
            model.note = result.note; model.loading = false
            model.selected = model.items.first?.id
        }
    }
}

private struct LibraryView: View {
    @Bindable var model: LibraryModel
    let title: String
    let open: (LibraryEntry) -> Void
    @FocusState private var searchFocused: Bool
    var body: some View {
        VStack(spacing: 0) {
            TextField("搜索\(title)…", text: $model.search).textFieldStyle(.roundedBorder)
                .focused($searchFocused).padding(16)
                .onSubmit { if let entry = model.filtered.first(where: { $0.id == model.selected }) ?? model.filtered.first { open(entry) } }
            if model.loading { Spacer(); ProgressView(); Spacer() }
            else {
                List(model.filtered, selection: $model.selected) { entry in
                    HStack(spacing: 12) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: entry.url.path)).resizable().frame(width: 32, height: 32)
                        VStack(alignment: .leading) {
                            Text(entry.name).lineLimit(1)
                            Text(entry.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button("打开") { open(entry) }.buttonStyle(.borderless)
                    }.padding(.vertical, 4).tag(entry.id).onTapGesture(count: 2) { open(entry) }
                }
                if model.filtered.isEmpty { Text(model.note.isEmpty ? "没有匹配的项目" : model.note).foregroundStyle(.secondary).padding(24) }
            }
        }.onAppear { searchFocused = true }
        .onChange(of: model.search) { _, _ in model.selected = model.filtered.first?.id }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in NSWorkspace.shared.open(url) } }
                }
            }
            return !providers.isEmpty
        }
    }
}
