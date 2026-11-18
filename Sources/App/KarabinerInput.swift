import AppKit
import Carbon.HIToolbox
import Darwin
import WindowSwitchCore

/// Karabiner's sender transmits a JSON string per edge using a local datagram.
/// A single read source preserves its order, including when AppKit is busy.
final class ShortcutSocket {
    let endpoint: URL
    private let directory: URL
    private var source: DispatchSourceRead?
    private var directoryFD: Int32 = -1

    init(directory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("io.github.morefreefg.WindowSwitch")) {
        self.directory = directory
        endpoint = directory.appendingPathComponent("input.sock")
    }

    func open(receive: @escaping @MainActor (String) -> Void) throws {
        if source != nil { return }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let dir = Darwin.open(directory.path, O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dir >= 0 else { throw POSIXError(.EACCES) }
        var info = stat()
        guard fstat(dir, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              flock(dir, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(dir); throw POSIXError(.EBUSY) }
        let fd = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard fd >= 0 else { Darwin.close(dir); throw POSIXError(.ENOBUFS) }
        do {
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            let path = endpoint.path.utf8CString
            guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.map { UInt8(bitPattern: $0) }) }
            unlink(endpoint.path) // Directory ownership and the instance lock were checked above.
            let addressLength = socklen_t(address.sun_len)
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, addressLength) }
            }
            guard bound == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw POSIXError(.EADDRINUSE) }
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            directoryFD = dir
            let read = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
            read.setEventHandler {
                var buffer = [UInt8](repeating: 0, count: 64)
                for _ in 0..<64 {
                    let count = recv(fd, &buffer, buffer.count, 0)
                    guard count >= 0 else { break }
                    if count < buffer.count, let edge = try? JSONDecoder().decode(String.self, from: Data(buffer.prefix(count))) {
                        receive(edge)
                    }
                }
            }
            read.setCancelHandler { Darwin.close(fd) }
            source = read
            read.resume()
        } catch {
            Darwin.close(fd); Darwin.close(dir)
            throw error
        }
    }

    func close() {
        guard let source else { return }
        source.cancel()
        self.source = nil
        unlink(endpoint.path)
        Darwin.close(directoryFD)
        directoryFD = -1
    }
}

private actor ProfileStore {
    private let url: URL
    private struct Stamp: Equatable {
        let modified: Date?
        let fileNumber: UInt64?
        let size: UInt64?
        init(url: URL) throws {
            let values = try FileManager.default.attributesOfItem(atPath: url.path)
            modified = values[.modificationDate] as? Date
            fileNumber = values[.systemFileNumber] as? UInt64
            size = values[.size] as? UInt64
        }
    }
    private var lastStamp: Stamp?
    private var lastModifier: String?
    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
        let config = xdg.flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil } ?? home.appendingPathComponent(".config")
        url = config.appendingPathComponent("karabiner/karabiner.json")
    }

    func update(modifier: String?, endpoint: String) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            guard modifier != nil else { return }
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let initial = Data(#"{"profiles":[{"name":"Default profile","selected":true}]}"#.utf8)
            do { try initial.write(to: url, options: .withoutOverwriting) }
            catch CocoaError.fileWriteFileExists { /* Another writer initialized the profile. */ }
        }
        let stamp = try Stamp(url: url)
        if stamp == lastStamp, lastModifier == modifier { return }
        var problem: Error?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &coordinationError) { file in
            do {
                let original = try Data(contentsOf: file)
                let rule = modifier.map { KarabinerRule.make(modifier: $0, endpoint: endpoint) }
                let new = try KarabinerProfile.updating(original, rule: rule)
                if new != original {
                    guard try Data(contentsOf: file) == original else { throw CocoaError(.fileWriteFileExists) }
                    try new.write(to: file, options: .atomic)
                }
            } catch { problem = error }
        }
        if let error = problem ?? coordinationError { throw error }
        lastStamp = try Stamp(url: url)
        lastModifier = modifier
    }
}

/// Only an opted-in, ready instance renews the rule. The expiry returns ownership
/// to macOS even on SIGKILL. One persistent CLI process carries all renewals.
final class KarabinerInput {
    static let cli = URL(fileURLWithPath: "/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli")
    private let socket = ShortcutSocket()
    private let store = ProfileStore()
    private var cliProcess: Process?
    private var writer: FileHandle?
    private var desired: ShortcutModifier?
    private var configured: ShortcutModifier?
    private var job: Task<Void, Never>?
    private var removeRule = false
    private var wasOptedIn = false
    var receive: ((String) -> Void)?
    var onStop: (() -> Void)?
    var status: ((String) -> Void)?

    static func installedVersion() -> String? {
        guard FileManager.default.isExecutableFile(atPath: cli.path) else { return nil }
        let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "org.pqrs.Karabiner-Elements.Settings")
            ?? URL(fileURLWithPath: "/Applications/Karabiner-Elements.app")
        return Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    static func supports(_ version: String?) -> Bool {
        guard let version else { return false }
        return version.compare("16.2", options: .numeric) != .orderedAscending
    }

    static var desktopAvailable: Bool {
        guard !IsSecureEventInputEnabled(),
              let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session[kCGSessionOnConsoleKey as String] as? Bool == true
            && session["CGSSessionScreenIsLocked"] as? Bool != true
    }

    func update(optedIn: Bool, modifier: ShortcutModifier?) {
        if wasOptedIn && !optedIn { removeRule = true }
        wasOptedIn = optedIn
        let next = optedIn ? modifier : nil
        if next != desired { stop(); desired = next }
        if let next, configured == next {
            do { try renew(next) }
            catch { stop(); status?("Karabiner connection unavailable. Using the standard shortcut.") }
        }
        guard job == nil, desired != nil || removeRule else { return }
        job = Task { [weak self] in
            guard let self else { return }
            let target = desired
            defer {
                job = nil
                if desired != target { update(optedIn: wasOptedIn, modifier: desired) }
            }
            do {
                try await store.update(modifier: target?.rawValue, endpoint: socket.endpoint.path)
                guard desired == target else { return }
                removeRule = false
                guard let target else { status?(""); return }
                if configured == nil {
                    try socket.open { [weak self] edge in
                        guard let self, configured == target else { return }
                        if edge == "tab" || edge == "reverseTab" {
                            guard Self.desktopAvailable else { stop(); return }
                        }
                        receive?(edge)
                    }
                    try startCLI()
                    try renew(target, reset: true)
                    configured = target
                    status?("Karabiner direct input is enabled for the window shortcut.")
                }
            } catch {
                guard desired == target else { return }
                stop()
                status?("Karabiner direct input unavailable. Check the active profile and Karabiner services.")
            }
        }
    }

    private func startCLI() throws {
        let process = Process(), pipe = Pipe()
        process.executableURL = Self.cli
        process.arguments = ["--set-variables-from-stdin"]
        process.standardInput = pipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        _ = fcntl(pipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        _ = fcntl(pipe.fileHandleForWriting.fileDescriptor, F_SETFL, O_NONBLOCK)
        try process.run()
        cliProcess = process
        writer = pipe.fileHandleForWriting
    }

    private func renew(_ modifier: ShortcutModifier, reset: Bool = false) throws {
        guard cliProcess?.isRunning == true, let writer,
              let index = KarabinerRule.modifiers.firstIndex(of: modifier.rawValue) else { throw POSIXError(.EPIPE) }
        var variables = [KarabinerRule.lease: Int(Date().timeIntervalSince1970 * 1000) + 5000,
                         KarabinerRule.selection: index + 1]
        if reset {
            for side in ["left", "right"] {
                for key in [modifier.rawValue, "shift"] { variables["windowswitch_direct_\(side)_\(key)"] = 0 }
            }
        }
        let data = try JSONEncoder().encode(variables)
        try writer.write(contentsOf: data + [10])
    }

    func stop() {
        desired = nil
        if let writer {
            try? writer.write(contentsOf: Data("{\"windowswitch_direct_until\":0}\n".utf8))
            try? writer.close()
        }
        writer = nil
        cliProcess = nil
        socket.close()
        if configured != nil { onStop?() }
        configured = nil
    }
}
