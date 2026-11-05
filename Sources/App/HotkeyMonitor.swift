import AppKit

final class HotkeyMonitor {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    var handler: ((CGEventType, CGEvent) -> Bool)?
    var onInterruption: (() -> Void)?
    private(set) var running = false

    func start() -> Bool {
        if running { return true }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue) | (1 << CGEventType.scrollWheel.rawValue)
        guard let newTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: CGEventMask(mask), callback: { _, type, event, info in
                guard let info else { return Unmanaged.passUnretained(event) }
                // This tap is installed exclusively on the main run loop.
                let consumed = MainActor.assumeIsolated {
                    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(info).takeUnretainedValue()
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        monitor.onInterruption?()
                        if let tap = monitor.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                        return false
                    }
                    return monitor.handler?(type, event) == true
                }
                return consumed ? nil : Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        tap = newTap
        let newSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        source = newSource
        CFRunLoopAddSource(CFRunLoopGetMain(), newSource, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        running = true
        return true
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        source = nil; tap = nil; running = false
    }
}
