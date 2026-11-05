import Foundation

public nonisolated struct BackgroundResourceSnapshot: Sendable {
    public let idleSeconds: Double
    public let loadPerCore: Double
    public let thermalSeverity: Int
    public let lowPowerMode: Bool
    public init(idleSeconds: Double, loadPerCore: Double, thermalSeverity: Int, lowPowerMode: Bool) {
        self.idleSeconds = idleSeconds; self.loadPerCore = loadPerCore
        self.thermalSeverity = thermalSeverity; self.lowPowerMode = lowPowerMode
    }
}

public nonisolated struct BackgroundWorkPolicy: Sendable {
    public let allowMetadata: Bool
    public let allowThumbnails: Bool
    public let intervalMultiplier: Double
    public init(_ snapshot: BackgroundResourceSnapshot) {
        allowMetadata = snapshot.idleSeconds >= 3 && snapshot.loadPerCore < 0.65
            && snapshot.thermalSeverity < 2 && !snapshot.lowPowerMode
        allowThumbnails = allowMetadata && snapshot.loadPerCore < 0.3 && snapshot.thermalSeverity == 0
        intervalMultiplier = allowThumbnails ? 1 : 4
    }
}
