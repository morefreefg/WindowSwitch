import AppKit
import WindowSwitchCore
import Darwin

nonisolated enum SystemBackgroundResources {
    static func snapshot() -> BackgroundResourceSnapshot {
        var load = 0.0
        if getloadavg(&load, 1) != 1 { load = Double(ProcessInfo.processInfo.activeProcessorCount) }
        let info = ProcessInfo.processInfo
        let idle = [CGEventType.keyDown, .mouseMoved, .leftMouseDown, .scrollWheel].map {
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0)
        }.min() ?? 0
        return BackgroundResourceSnapshot(idleSeconds: idle, loadPerCore: load / Double(max(1, info.activeProcessorCount)),
            thermalSeverity: info.thermalState.rawValue, lowPowerMode: info.isLowPowerModeEnabled)
    }
}

nonisolated struct BackgroundPreloadConfiguration: Equatable, Sendable {
    let enabled: Bool
    let thumbnails: Bool
    let interval: Double
    let query: WindowQuery
    let request: ThumbnailRequest
}

struct PreloadedThumbnail {
    let image: NSImage
    let stamp: ThumbnailStamp
    let updated: Date
}
