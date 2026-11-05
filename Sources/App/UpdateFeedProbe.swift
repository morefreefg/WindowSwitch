import Foundation
import Sparkle

/// Explicit diagnostic: checks the signed feed without downloading/installing
/// an update or presenting the update UI. It never installs input hooks.
@MainActor final class UpdateFeedProbe: NSObject, SPUUpdaterDelegate {
    private var result: [String: Any]?
    private lazy var controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
    func run() async -> [String: Any] {
        controller.updater.sendsSystemProfile = false
        do { try controller.updater.start() }
        catch { return ["passed": false, "error": error.localizedDescription] }
        controller.updater.checkForUpdateInformation()
        for _ in 0..<300 {
            if let result { return result }
            do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
        }
        return ["passed": false, "error": "Timed out checking signed update feed"]
    }
    func allowedChannels(for updater: SPUUpdater) -> Set<String> { ["rc"] }
    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        result = ["passed": !appcast.items.isEmpty, "items": appcast.items.count,
                  "rcItems": appcast.items.filter { $0.channel == "rc" }.count,
                  "signedFeedRequired": Bundle.main.object(forInfoDictionaryKey: "SURequireSignedFeed") as? Bool == true,
                  "versions": appcast.items.map(\.displayVersionString)]
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let failure = error as NSError
        // Sparkle reports a successful check with no newer version as an error.
        if failure.domain == SUSparkleErrorDomain, failure.code == Int(SUError.noUpdateError.rawValue) {
            if result == nil { result = ["passed": true, "upToDate": true] }
            return
        }
        result = ["passed": false, "error": error.localizedDescription]
    }
}
