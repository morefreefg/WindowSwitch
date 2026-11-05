public nonisolated struct PermissionReadiness: Sendable {
    public let accessibility: Bool
    public let screenRecording: Bool
    public let previewsEnabled: Bool
    public init(accessibility: Bool, screenRecording: Bool, previewsEnabled: Bool) {
        self.accessibility = accessibility; self.screenRecording = screenRecording; self.previewsEnabled = previewsEnabled
    }
    public var canStart: Bool { accessibility && (!previewsEnabled || screenRecording) }
}
