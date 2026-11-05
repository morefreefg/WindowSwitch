import Testing
@testable import WindowSwitchCore

@Suite struct BackgroundWorkPolicyTests {
    @Test func activeInputDefersAllWork() {
        let policy = BackgroundWorkPolicy(.init(idleSeconds: 1, loadPerCore: 0, thermalSeverity: 0, lowPowerMode: false))
        #expect(!policy.allowMetadata && !policy.allowThumbnails)
    }
    @Test func idleCoolSystemMayCapture() {
        let policy = BackgroundWorkPolicy(.init(idleSeconds: 30, loadPerCore: 0.1, thermalSeverity: 0, lowPowerMode: false))
        #expect(policy.allowMetadata && policy.allowThumbnails && policy.intervalMultiplier == 1)
    }
    @Test func moderateLoadKeepsOnlyInfrequentMetadata() {
        let policy = BackgroundWorkPolicy(.init(idleSeconds: 30, loadPerCore: 0.4, thermalSeverity: 0, lowPowerMode: false))
        #expect(policy.allowMetadata && !policy.allowThumbnails && policy.intervalMultiplier > 1)
    }
    @Test(arguments: [(0.9, 0, false), (0.0, 2, false), (0.0, 0, true)])
    func heavyLoadHeatOrLowPowerPauses(load: Double, heat: Int, lowPower: Bool) {
        let policy = BackgroundWorkPolicy(.init(idleSeconds: 30, loadPerCore: load, thermalSeverity: heat, lowPowerMode: lowPower))
        #expect(!policy.allowMetadata && !policy.allowThumbnails)
    }
}
