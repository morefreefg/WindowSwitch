import Foundation
import Testing
@testable import WindowSwitchCore

@Suite struct SwitchDiagnosticLogTests {
    @Test func fullDefaultArchiveRotatesAtOneHundredMegabytes() throws {
        let directory = URL(fileURLWithPath: "/tmp").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for i in 0..<10 {
            let name = i == 0 ? "switch.jsonl" : "switch.\(i).jsonl"
            let url = directory.appendingPathComponent(name)
            try Data([UInt8(i)]).write(to: url)
            let file = try FileHandle(forWritingTo: url)
            try file.truncate(atOffset: 10_000_000)
            try file.close()
        }
        let log = SwitchDiagnosticLog(directory: directory)
        log.record("rotation")
        log.flush()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        let bytes = try files.reduce(0) { try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        #expect(files.count == 10)
        #expect((90_000_000...100_000_000).contains(bytes))
        let oldest = try FileHandle(forReadingFrom: directory.appendingPathComponent("switch.9.jsonl"))
        defer { try? oldest.close() }
        #expect(try oldest.read(upToCount: 1) == Data([8]))
    }

    @Test func concurrentWritersRotateWithinTheSharedLimitAcrossRestarts() throws {
        let directory = URL(fileURLWithPath: "/tmp").appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gesture = UUID()
        func writer() -> SwitchDiagnosticLog { SwitchDiagnosticLog(directory: directory, segmentBytes: 1000, segments: 3) }
        let first = writer(), second = writer()
        for i in 0..<120 {
            (i.isMultiple(of: 2) ? first : second).record("edge", gesture: gesture, ["sequence": String(i)])
        }
        first.flush()
        second.flush()
        let restarted = writer()
        restarted.record("restart", gesture: gesture)
        restarted.flush()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(Set(files.map(\.lastPathComponent)) == ["switch.jsonl", "switch.1.jsonl", "switch.2.jsonl"])
        var total = 0, rows = 0
        for url in files {
            let data = try Data(contentsOf: url)
            total += data.count
            #expect(data.count <= 1000)
            #expect(data.last == 10)
            for line in data.split(separator: 10) {
                let record = try #require(JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])
                #expect(record["gesture"] as? String == gesture.uuidString)
                rows += 1
            }
        }
        #expect(total <= 3000 && rows > 3 && rows < 121)
        let latest = try String(contentsOf: directory.appendingPathComponent("switch.jsonl"), encoding: .utf8)
        #expect(latest.split(separator: "\n").last?.contains("\"restart\"") == true)
    }
}
