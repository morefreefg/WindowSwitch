import Foundation

/// A switching session keeps its original order until dismissed, even as focus changes.
public nonisolated struct SwitchSelection: Sendable {
    public private(set) var items: [WindowItem] = []
    public private(set) var selectedID: String?
    public var search = ""
    public init() {}

    public var filtered: [WindowItem] {
        guard !search.isEmpty else { return items }
        return items.filter {
            "\($0.appName) \($0.title)".localizedStandardContains(search)
        }
    }
    public var selected: WindowItem? {
        filtered.first { $0.id == selectedID } ?? filtered.first
    }
    public mutating func start(_ windows: [WindowItem], reverse: Bool = false, advance: Bool = true) {
        items = windows; search = ""
        selectedID = windows.first?.id
        if advance { move(reverse ? -1 : 1) }
    }
    public mutating func move(_ delta: Int) {
        let visible = filtered
        guard !visible.isEmpty else { selectedID = nil; return }
        let current = visible.firstIndex { $0.id == selectedID } ?? 0
        let next = ((current + delta) % visible.count + visible.count) % visible.count
        selectedID = visible[next].id
    }
    public mutating func select(_ id: String) {
        if filtered.contains(where: { $0.id == id }) { selectedID = id }
    }
    public mutating func moveRow(_ rows: Int, columns: Int) {
        let visible = filtered
        guard let current = visible.firstIndex(where: { $0.id == selectedID }) else { return }
        let destination = current + rows * max(1, columns)
        if visible.indices.contains(destination) { selectedID = visible[destination].id }
    }
    public mutating func remove(_ id: String) {
        let index = filtered.firstIndex { $0.id == id } ?? 0
        items.removeAll { $0.id == id }
        if selectedID == id {
            let remaining = filtered
            selectedID = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)].id
        }
    }
    public mutating func removeApplication(pid: Int32) {
        for id in items.filter({ $0.pid == pid }).map(\.id) { remove(id) }
    }
}
