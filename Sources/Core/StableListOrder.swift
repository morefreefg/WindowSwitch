import Foundation

/// Updates an open switcher list without moving what the user is looking at:
/// windows already shown keep their order (with refreshed data), windows that went
/// away are removed, and new windows are appended. Recency reordering waits for the
/// next time the list opens.
public nonisolated enum StableListOrder {
    public static func merge(shown: [WindowItem], latest: [WindowItem]) -> [WindowItem] {
        let latestByID = Dictionary(latest.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let kept = shown.compactMap { latestByID[$0.id] }
        let keptIDs = Set(kept.map(\.id))
        return kept + latest.filter { !keptIDs.contains($0.id) }
    }
}
