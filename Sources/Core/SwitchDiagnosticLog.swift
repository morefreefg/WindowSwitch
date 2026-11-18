import Darwin
import Foundation
import os

/// Entries share a gesture ID across input, target selection and focus verification.
public final class SwitchDiagnosticLog: @unchecked Sendable {
    @TaskLocal public static var currentGesture: UUID?
    public static let shared: SwitchDiagnosticLog = {
        let arguments = ProcessInfo.processInfo.arguments
        let directory: URL
        if arguments.contains("--verify-fixture"), let index = arguments.firstIndex(of: "--fixture-session"),
           arguments.indices.contains(index + 1), let session = UUID(uuidString: arguments[index + 1]) {
            directory = URL(fileURLWithPath: "/tmp/codex-windowswitch/Fixture-\(session.uuidString)/Diagnostics")
        } else {
            directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/WindowSwitch")
        }
        return SwitchDiagnosticLog(directory: directory)
    }()

    private struct Entry: Encodable {
        let timeMS: Double
        let uptimeNS: UInt64
        let pid: Int32
        let gesture: UUID?
        let event: String
        let fields: [String: String]
        let droppedBefore: Int?
    }

    private let directory: URL
    private let segmentBytes: Int
    private let segments: Int
    private let queue = DispatchQueue(label: "WindowSwitch.diagnostics", qos: .utility)
    private let lock = NSLock()
    private var pending = 0
    private var dropped = 0
    // Only the serial writer accesses the encoder and error throttle.
    private let encoder = JSONEncoder()
    private var lastWarning = Date.distantPast
    private let logger = Logger(subsystem: "io.github.morefreefg.WindowSwitch", category: "diagnostics")

    init(directory: URL, segmentBytes: Int = 10_000_000, segments: Int = 10) {
        precondition(segmentBytes > 0 && segments > 0)
        self.directory = directory
        self.segmentBytes = segmentBytes
        self.segments = segments
    }

    public func record(_ event: String, gesture: UUID? = SwitchDiagnosticLog.currentGesture, _ fields: [String: String] = [:]) {
        lock.lock()
        guard pending < 1024 else { dropped += 1; lock.unlock(); return }
        pending += 1
        let lost = dropped
        dropped = 0
        lock.unlock()
        let entry = Entry(timeMS: Date().timeIntervalSince1970 * 1000, uptimeNS: DispatchTime.now().uptimeNanoseconds,
                          pid: getpid(), gesture: gesture, event: event, fields: fields, droppedBefore: lost == 0 ? nil : lost)
        queue.async {
            defer { self.lock.withLock { self.pending -= 1 } }
            do {
                var line = try self.encoder.encode(entry)
                line.append(0x0a)
                try self.append(line)
            } catch {
                self.lock.withLock { self.dropped += lost + 1 }
                if Date().timeIntervalSince(self.lastWarning) >= 60 {
                    self.lastWarning = Date()
                    self.logger.error("Diagnostic write failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    public func flush() { queue.sync {} }

    private func name(_ index: Int) -> String { index == 0 ? "switch.jsonl" : "switch.\(index).jsonl" }

    private func append(_ data: Data) throws {
        guard data.count <= segmentBytes else { throw POSIXError(.EFBIG) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let dir = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dir >= 0 else { throw posixError() }
        defer { close(dir) }
        // A verifier or a second process must not rotate underneath a writer.
        guard flock(dir, LOCK_EX) == 0 else { throw posixError() }
        func openCurrent() throws -> Int32 {
            let fd = openat(dir, name(0), O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw posixError() }
            return fd
        }
        var fd = try openCurrent()
        defer { if fd >= 0 { close(fd) } }
        var size = lseek(fd, 0, SEEK_END)
        guard size >= 0 else { throw posixError() }
        if size + Int64(data.count) > Int64(segmentBytes) {
            close(fd)
            fd = -1
            if segments == 1 {
                guard unlinkat(dir, name(0), 0) == 0 else { throw posixError() }
            } else {
                for i in stride(from: segments - 1, through: 1, by: -1) {
                    if renameat(dir, name(i - 1), dir, name(i)) != 0 && errno != ENOENT { throw posixError() }
                }
            }
            fd = try openCurrent()
            size = 0
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else {
                    let failure = posixError()
                    _ = ftruncate(fd, size)
                    throw failure
                }
                offset += count
            }
        }
    }

    private func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
