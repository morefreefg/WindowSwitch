import Foundation

/// A single in-memory ordering shared by quick switching and the full list.
/// Untouched windows keep their existing compositor order.
public nonisolated struct WindowRecency: Sendable {
    private struct Key: Hashable, Sendable { let pid: Int32; let windowID: UInt32 }
    private var ranks: [Key: UInt64] = [:]
    private var clock: UInt64 = 0
    private var last: Key?
    public init() {}

    @discardableResult
    public mutating func record(pid: Int32, windowID: UInt32) -> Bool {
        let key = Key(pid: pid, windowID: windowID)
        guard last != key else { return false }
        clock &+= 1; ranks[key] = clock; last = key
        if ranks.count > 2048, let oldest = ranks.min(by: { $0.value < $1.value })?.key { ranks[oldest] = nil }
        return true
    }
    public mutating func remove(pid: Int32, windowID: UInt32) {
        let key = Key(pid: pid, windowID: windowID)
        ranks[key] = nil
        if last == key { last = nil }
    }
    public mutating func removeProcess(_ pid: Int32) {
        ranks = ranks.filter { $0.key.pid != pid }
        if last?.pid == pid { last = nil }
    }
    public func ordered(_ windows: [WindowItem]) -> [WindowItem] {
        func rank(_ item: WindowItem) -> UInt64 {
            item.windowID.flatMap { ranks[Key(pid: item.pid, windowID: $0)] } ?? 0
        }
        return windows.enumerated().sorted {
            let left = rank($0.element), right = rank($1.element)
            return left == right ? $0.offset < $1.offset : left > right
        }.map(\.element)
    }
}
