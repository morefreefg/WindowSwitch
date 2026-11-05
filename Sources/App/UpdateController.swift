import AppKit
import Observation
import Sparkle

@Observable final class UpdateController: NSObject, SPUUpdaterDelegate {
    var automaticChecks: Bool {
        didSet { if updater.automaticallyChecksForUpdates != automaticChecks { updater.automaticallyChecksForUpdates = automaticChecks } }
    }
    var automaticDownloads: Bool {
        didSet { if updater.automaticallyDownloadsUpdates != automaticDownloads { updater.automaticallyDownloadsUpdates = automaticDownloads } }
    }
    var includeRC: Bool {
        didSet {
            UserDefaults.standard.set(includeRC, forKey: "includeReleaseCandidates")
            if started { updater.resetUpdateCycleAfterShortDelay() }
        }
    }
    var supportsInAppUpdates: Bool { Bundle.main.bundleIdentifier == "io.github.morefreefg.WindowSwitch" }
    private(set) var canCheck = false
    private(set) var lastChecked: Date?
    private(set) var status = ""
    @ObservationIgnored private var started = false
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private lazy var standard = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
    private var updater: SPUUpdater { standard.updater }

    override init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: ["includeReleaseCandidates": true])
        automaticChecks = defaults.object(forKey: "SUEnableAutomaticChecks") as? Bool ?? true
        automaticDownloads = defaults.object(forKey: "SUAutomaticallyUpdate") as? Bool ?? false
        includeRC = defaults.bool(forKey: "includeReleaseCandidates")
        super.init()
    }

    func start() {
        guard supportsInAppUpdates else {
            let message = "此内测安装可从 GitHub 下载新版；公开发行版支持应用内自动更新。"
            if status != message { status = message }; return
        }
        guard !started else { return }
        updater.sendsSystemProfile = false
        do { try updater.start() }
        catch { status = error.localizedDescription; return }
        started = true
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
                let value = change.newValue ?? false
                Task { @MainActor in self?.canCheck = value }
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] _, change in
                let value = change.newValue ?? true
                Task { @MainActor in self?.automaticChecks = value }
            },
            updater.observe(\.automaticallyDownloadsUpdates, options: [.initial, .new]) { [weak self] _, change in
                let value = change.newValue ?? false
                Task { @MainActor in self?.automaticDownloads = value }
            },
            updater.observe(\.lastUpdateCheckDate, options: [.initial, .new]) { [weak self] _, change in
                let value = change.newValue ?? nil
                Task { @MainActor in self?.lastChecked = value }
            }
        ]
    }
    @objc func checkForUpdates(_ sender: Any? = nil) {
        guard supportsInAppUpdates else {
            NSWorkspace.shared.open(URL(string: "https://github.com/morefreefg/WindowSwitch/releases")!); return
        }
        start()
        guard canCheck || updater.canCheckForUpdates else { return }
        standard.checkForUpdates(sender)
    }
    func allowedChannels(for updater: SPUUpdater) -> Set<String> { includeRC ? ["rc"] : [] }
    func restoreDefaults() {
        automaticChecks = true; automaticDownloads = false; includeRC = true
    }
}
