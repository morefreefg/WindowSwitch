import AppKit
import WindowSwitchCore

/// Preserve the relevant WindowServer milestones while the system's own log still has them.
@MainActor enum WindowServerDiagnostics {
    private static var nextProbe = Date.distantPast
    private static var probing = false

    static func sample(gesture: UUID, window: WindowItem, submitted: Date, finished: Date) {
        guard !probing, finished >= nextProbe, let id = window.windowID, !window.bundleID.isEmpty else { return }
        probing = true
        nextProbe = finished.addingTimeInterval(30)
        let bundle = window.bundleID
        Task {
            await Task.detached(priority: .utility) { collect(gesture, id: id, bundle: bundle, start: submitted, end: finished) }.value
            probing = false
        }
    }

    nonisolated private static func collect(_ gesture: UUID, id: UInt32, bundle: String, start: Date, end: Date) {
        let window = String(id, radix: 16)
        let front = " " + bundle.lowercased()
        let key = "request window " + window + " set active key appearance"
        let order = "order window: " + window + " op: 1 relative: 0"
        let predicate = NSPredicate(format: "process == 'WindowServer' AND subsystem == 'com.apple.SkyLight' AND category == 'packages' AND ((eventMessage CONTAINS '[SetFrontProcess]: new foreground connection' AND eventMessage ENDSWITH[c] %@) OR eventMessage ENDSWITH %@ OR eventMessage ENDSWITH %@)", front, key, order)
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US_POSIX")
        clock.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = ["show", "--info", "--style", "ndjson", "--start", clock.string(from: max(start, end.addingTimeInterval(-10))),
                             "--end", clock.string(from: end.addingTimeInterval(1)), "--predicate", predicate.predicateFormat]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        var count = 0
        var status = "unavailable"
        defer { SwitchDiagnosticLog.shared.record("systemProbe", gesture: gesture, ["status": status, "matches": String(count)]) }
        do { try process.run() } catch { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 8) {
            if process.isRunning { process.terminate() }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return }
        status = "completed"
        clock.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZZZ"
        for line in data.split(separator: 10) {
            guard let row = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let message = row["eventMessage"] as? String, let stamp = row["timestamp"] as? String,
                  let time = clock.date(from: stamp), time >= start.addingTimeInterval(-0.001), time <= end.addingTimeInterval(0.001) else { continue }
            let phase: String
            if message.hasSuffix(key) { phase = "keyAppearanceRequest" }
            else if message.hasSuffix(order) { phase = "orderFrontRequest" }
            else if message.lowercased().hasSuffix(front) { phase = "frontProcess" }
            else { continue }
            count += 1
            SwitchDiagnosticLog.shared.record("windowServer", gesture: gesture, ["phase": phase, "systemTime": stamp,
                "sinceSubmitMS": String(time.timeIntervalSince(start) * 1000), "targetID": String(id), "bundle": bundle])
        }
    }
}
