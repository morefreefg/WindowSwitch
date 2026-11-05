import Foundation

/// `*` expands to `.*`; all other regular-expression syntax is preserved.
public nonisolated struct WindowRule: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var bundleID: String
    public var titlePattern: String
    public var isEnabled: Bool

    public init(id: UUID = UUID(), bundleID: String, titlePattern: String = "*", isEnabled: Bool = true) {
        self.id = id
        self.bundleID = bundleID
        self.titlePattern = titlePattern
        self.isEnabled = isEnabled
    }

    public var validationError: String? {
        do { _ = try expression(); return nil }
        catch { return error.localizedDescription }
    }

    public func matches(bundleID candidateBundleID: String, title: String) -> Bool {
        guard isEnabled, bundleID == candidateBundleID,
              let regex = try? expression() else { return false }
        let range = NSRange(title.startIndex..<title.endIndex, in: title)
        return regex.firstMatch(in: title, range: range) != nil
    }

    public func matches(_ item: WindowItem) -> Bool {
        matches(bundleID: item.bundleID, title: item.title)
    }

    public static func excludes(_ item: WindowItem, rules: [WindowRule]) -> Bool {
        rules.contains { $0.matches(item) }
    }

    private func expression() throws -> NSRegularExpression {
        let regex = titlePattern.replacingOccurrences(of: "*", with: ".*")
        // SELF MATCHES requires the entire input to match, including alternations.
        return try NSRegularExpression(pattern: "\\A(?:" + regex + ")\\z")
    }
}
