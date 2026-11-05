import Testing
import WindowSwitchCore

@Suite struct PermissionReadinessTests {
    @Test func accessibilityAlwaysRequired() {
        #expect(!PermissionReadiness(accessibility: false, screenRecording: true, previewsEnabled: true).canStart)
        #expect(!PermissionReadiness(accessibility: false, screenRecording: false, previewsEnabled: false).canStart)
    }
    @Test func previewsRequireScreenRecording() {
        #expect(!PermissionReadiness(accessibility: true, screenRecording: false, previewsEnabled: true).canStart)
        #expect(PermissionReadiness(accessibility: true, screenRecording: true, previewsEnabled: true).canStart)
    }
    @Test func noPreviewDoesNotRequestUnneededPermission() {
        #expect(PermissionReadiness(accessibility: true, screenRecording: false, previewsEnabled: false).canStart)
    }
}
