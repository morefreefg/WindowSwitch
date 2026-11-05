import AppKit
import ApplicationServices
import Darwin
import WindowSwitchCore

private nonisolated struct FunctionalCheck: Codable {
    let name: String
    let status: String
    let required: Bool
    let evidence: [String: String]
}

private nonisolated struct FunctionalReport: Codable {
    let version: Int
    let status: String
    let session: String
    let accessibility: Bool
    let screenCapture: Bool
    let displayCount: Int
    let fixturePIDs: [Int32]
    let checks: [FunctionalCheck]
}

/// This opt-in verifier only mutates our session-tagged disposable fixture.
/// No permission requests, user documents, or Dock preference changes. Only
/// --dock-input enables a temporary event tap and one strictly hit-tested click.
@MainActor
enum FunctionalVerifier {
    static func run() async {
        let run = FixtureVerificationRun()
        await run.execute()
        NSApp.terminate(nil)
    }
}

@MainActor
private final class FixtureVerificationRun {
    private let bundleID = "io.github.morefreefg.WindowSwitchFixture"
    private let service = WindowService()
    private let sentinelService = WindowService()
    private var checks: [FunctionalCheck] = []
    private var fixturePIDs: Set<Int32> = []
    private let session: String
    private let fixturePath: String
    private let extended: Bool

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        session = value("--fixture-session") ?? ""
        fixturePath = URL(fileURLWithPath: value("--fixture-app")
            ?? "/tmp/codex-windowswitch/Fixture/WindowSwitchFixture.app")
            .standardizedFileURL.resolvingSymlinksInPath().path
        extended = arguments.contains("--extended")
    }

    func execute() async {
        defer { writeReport() }
        guard !session.isEmpty else {
            record("fixture-session", "blocked", evidence: ["reason": "Missing --fixture-session; no fixture was touched"])
            return
        }
        let targets = NSWorkspace.shared.runningApplications.filter { matches($0) }
        fixturePIDs = Set(targets.map(\.processIdentifier))
        guard let primary = targets.first(where: { state($0.processIdentifier)?["sentinel"] as? Bool == false }) else {
            record("fixture-discovery", "blocked", evidence: ["reason": "No matching session-tagged fixture process"])
            return
        }
        let pid = primary.processIdentifier
        guard AXIsProcessTrusted() else {
            record("accessibility", "blocked", evidence: ["reason": "WindowSwitch lacks Accessibility permission; no window actions ran"])
            cleanup()
            return
        }
        record("accessibility", "passed")
        let ready = await wait {
            targets.allSatisfy { application in
                guard let state = self.state(application.processIdentifier),
                      state["launchReady"] as? Bool == true,
                      state["activationObserved"] as? Bool == true,
                      let expected = state["expectedWindowCount"] as? Int,
                      let windows = state["windows"] as? [[String: Any]] else { return false }
                return windows.count >= expected
            }
        }
        let baselinePID = targets.first(where: { state($0.processIdentifier)?["sentinel"] as? Bool == true })?.processIdentifier ?? pid
        let settled = ready ? await waitForStableFixtureFront(pid: baselinePID) : false
        record("fixture-launch-readiness", ready && settled ? "passed" : "blocked", evidence: [
            "allWindowsCreatedAndActivationObserved": "\(ready)", "baselinePID": "\(baselinePID)",
            "frontmostAndFocusedStable250ms": "\(settled)"])
        guard ready && settled else { cleanup(); return }
        await service.setSingleWindowFocus(true)
        await sentinelService.setSingleWindowFocus(true)
        var windows = await discover(pid)
        guard let first = windows.first(where: { $0.title == "WSFixture_A" }),
              let firstID = first.windowID, windows.count >= 3 else {
            record("fixture-discovery", "failed", evidence: ["count": "\(windows.count)", "reason": "Expected A/B/C fixture windows with real IDs"])
            cleanup()
            return
        }
        record("current-application-discovery", "passed", evidence: ["count": "\(windows.count)", "pid": "\(pid)"])
        if ProcessInfo.processInfo.arguments.contains("--quick-switch") {
            await verifyQuickSwitch(primaryPID: pid, first: first, targets: targets)
            cleanup(); return
        }
        if ProcessInfo.processInfo.arguments.contains("--render-ui") {
            await renderFixtureUI(windows.filter { $0.title.hasPrefix("WSFixture_") })
            cleanup(); return
        }
        await verifyGlobalDiscovery(pid: pid, initial: windows)
        await verifyScreenFiltering(pid: pid, initial: windows)

        let original = first.frame
        let focused = await act(.focus, on: first)
        let accurate = await wait { self.focusedWindowID(pid: pid) == firstID }
        var focusEvidence = focusObservation(pid: pid)
        focusEvidence.merge(await service.focusDiagnostics(), uniquingKeysWith: { _, new in new })
        focusEvidence.merge(["windowID": "\(firstID)", "accepted": "\(focused)", "exactObserved": "\(accurate)"], uniquingKeysWith: { _, new in new })
        record("focus-exact-window", focused && accurate ? "passed" : "failed", evidence: focusEvidence)

        if let sentinel = targets.first(where: { state($0.processIdentifier)?["sentinel"] as? Bool == true }) {
            await verifyOtherDisplayRemainsBehindSentinel(pid: pid, firstID: firstID,
                                                        sentinelPID: sentinel.processIdentifier)
        } else {
            record("single-window-other-display-z-order", "skipped", required: false,
                   evidence: ["reason": "No session-tagged sentinel; run Scripts/verify-functional.sh"])
        }

        await verifyMinimize(pid: pid, windowID: firstID)
        let area = visibleArea(for: original)
        for action in [WindowAction.center, .snapLeft, .snapRight, .maximize, .compact] {
            guard let item = await fresh(pid, firstID), let area else {
                record("layout-\(action.rawValue)", "failed", evidence: ["reason": "Fixture window or display unavailable"])
                continue
            }
            let before = item.frame
            let expected = expectedFrame(action, current: before, area: area)
            let accepted = await act(action, on: item)
            let observed = await waitFrame(pid: pid, windowID: firstID, expected: expected)
            record("layout-\(action.rawValue)", accepted && observed ? "passed" : "failed",
                   evidence: ["expected": describe(expected), "observed": describe((await fresh(pid, firstID))?.frame)])
        }
        if let item = await fresh(pid, firstID) {
            let accepted = await act(.restore, on: item)
            let restored = await waitFrame(pid: pid, windowID: firstID, expected: original)
            record("layout-restore", accepted && restored ? "passed" : "failed",
                   evidence: ["expected": describe(original), "observed": describe((await fresh(pid, firstID))?.frame)])
        }

        if let item = await fresh(pid, firstID) {
            let countBefore = (await discover(pid)).count
            let sent = await act(.newWindow, on: item)
            let appeared = await waitAsync { (await self.discover(pid)).count > countBefore }
            record("new-window-command-n", sent && appeared ? "passed" : "failed",
                   evidence: ["before": "\(countBefore)", "after": "\((await discover(pid)).count)"])
        }
        for action in [WindowAction.newTab, .openFile] {
            if let item = await fresh(pid, firstID) {
                let before = actionCount(action.rawValue, pid: pid)
                let sent = await act(action, on: item)
                let handled = await wait { self.actionCount(action.rawValue, pid: pid) > before }
                record("\(action.rawValue)-targeted-command", sent && handled ? "passed" : "failed",
                       evidence: ["before": "\(before)", "after": "\(actionCount(action.rawValue, pid: pid))"])
            }
        }

        if CGPreflightScreenCaptureAccess(), let item = await fresh(pid, firstID), let id = item.windowID {
            let image = await service.thumbnail(windowID: id, maxSize: 320)
            let valid = image.map { $0.width > 0 && $0.height > 0 && max($0.width, $0.height) <= 320 } == true
            record("thumbnail-window-only", valid ? "passed" : "failed", evidence: [
                "windowID": "\(id)", "width": "\(image?.width ?? 0)", "height": "\(image?.height ?? 0)",
                "backend": (await service.captureDiagnostics(windowID: id))["backend"] ?? "none"])
            let full = await service.fullWindowPreview(windowID: id, allowRetina: true)
            let fullValid = full.map { $0.width == Int(item.frame.width) * 2 && $0.height == Int(item.frame.height) * 2 } == true
            record("full-size-preview-resolution", fullValid ? "passed" : "failed", evidence: [
                "width": "\(full?.width ?? 0)", "height": "\(full?.height ?? 0)",
                "backend": (await service.captureDiagnostics(windowID: id))["backend"] ?? "none"])
            await service.startBackgroundMaintenance()
            let pending = Task { await service.thumbnail(windowID: id, maxPixelSize: CGSize(width: 331, height: 181), interpolationQuality: 2) }
            let began = Date()
            let duringCapture = await discover(pid)
            let elapsed = Date().timeIntervalSince(began) * 1000
            let lowImage = await pending.value
            await service.stopBackgroundMaintenance()
            record("discovery-during-preview", lowImage != nil && duringCapture.contains(where: { $0.windowID == id }) && elapsed < 250 ? "passed" : "failed", evidence: [
                "listMS": "\(elapsed)", "windowCount": "\(duringCapture.count)", "captureQuality": "2"])
        } else {
            record("thumbnail-window-only", "blocked", evidence: ["reason": "Missing screen-capture permission or fixture window"])
        }

        if extended {
            // Each independent scenario gets a current ID. Native fullscreen can
            // replace a CG window, so never reuse its pre-transition ID for Spaces.
            if let target = (await discover(pid)).first(where: { $0.title.hasPrefix("WSFixture_A") }), let id = target.windowID {
                await verifySpaces(pid: pid, windowID: id)
            } else { record("space-move-round-trip", "blocked", evidence: ["reason": "Fixture A unavailable before Space scenario"] ) }
            if let target = (await discover(pid)).first(where: { $0.title.hasPrefix("WSFixture_A") }), let id = target.windowID {
                await verifyFullscreen(pid: pid, windowID: id)
            } else { record("native-fullscreen-round-trip", "blocked", evidence: ["reason": "Fixture A unavailable before fullscreen scenario"] ) }
        } else {
            record("native-fullscreen-round-trip", "skipped", required: false, evidence: ["reason": "Requires --extended"])
            record("space-move-round-trip", "skipped", required: false, evidence: ["reason": "Requires --extended"])
        }
        windows = await discover(pid)
        if let closeTarget = windows.first(where: { $0.title.hasPrefix("WSFixture_C") }), let closeID = closeTarget.windowID {
            let accepted = await act(.close, on: closeTarget)
            let removed = await waitAsync { !(await self.discover(pid)).contains(where: { $0.windowID == closeID }) }
            record("close-fixture-window", accepted && removed ? "passed" : "failed", evidence: ["windowID": "\(closeID)"])
        } else {
            record("close-fixture-window", "failed", evidence: ["reason": "Fixture C unavailable"])
        }
        await service.cancelPendingThumbnails()
        cleanup()
    }

    private func verifyGlobalDiscovery(pid: Int32, initial: [WindowItem]) async {
        var query = query(pid: pid)
        query.mode = .windows
        query.excludedBundleIDs = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier).filter { $0 != bundleID })
        let all = await service.discover(query)
        let expectedIDs = Set(initial.compactMap(\.windowID))
        let actualIDs = Set(all.filter { $0.pid == pid }.compactMap(\.windowID))
        record("all-windows-discovery", expectedIDs.isSubset(of: actualIDs) && all.allSatisfy { $0.bundleID == bundleID } ? "passed" : "failed",
               evidence: ["fixtureWindowCount": "\(all.count)", "mainFixtureCount": "\(actualIDs.count)"])
        query.mode = .applications
        let applications = await service.discover(query)
        let appPIDs = Set(applications.map(\.pid))
        let unique = appPIDs.count == applications.count
        record("applications-discovery", fixturePIDs.isSubset(of: appPIDs) && unique
            && applications.allSatisfy { $0.bundleID == bundleID && $0.id.hasPrefix("app:") } ? "passed" : "failed",
               evidence: ["applicationCount": "\(applications.count)", "expectedSessionProcesses": "\(fixturePIDs.count)"])
    }

    private func verifyScreenFiltering(pid: Int32, initial: [WindowItem]) async {
        let areas = displayAreas()
        guard areas.count >= 2 else {
            record("all-screens-filter", "skipped", required: false, evidence: ["reason": "Only one physical display"])
            return
        }
        var query = query(pid: pid)
        query.allScreens = false
        query.screenBounds = areas[0].whole
        let filtered = await service.discover(query)
        let expected = Set(initial.filter { $0.frame.intersects(areas[0].whole) }.compactMap(\.windowID))
        let actual = Set(filtered.compactMap(\.windowID))
        record("all-screens-filter", actual == expected && filtered.count < initial.count ? "passed" : "failed",
               evidence: ["all": "\(initial.count)", "firstDisplay": "\(filtered.count)"])
    }

    private func verifyOtherDisplayRemainsBehindSentinel(pid: Int32, firstID: UInt32, sentinelPID: Int32) async {
        guard NSScreen.screens.count >= 2 else {
            record("single-window-other-display-z-order", "skipped", required: false, evidence: ["reason": "Only one physical display"])
            return
        }
        guard let other = (await discover(pid)).first(where: { $0.title == "WSFixture_B" }), let otherID = other.windowID,
              let sentinel = (await sentinelService.discover(query(pid: sentinelPID))).first,
              let sentinelID = sentinel.windowID else {
            record("single-window-other-display-z-order", "blocked", evidence: ["reason": "Missing fixture B or sentinel window"])
            return
        }
        let sentinelAccepted = await act(.focus, on: sentinel, using: sentinelService)
        let sentinelExact = await wait { self.focusedWindowID(pid: sentinelPID) == sentinelID }
        let before = fixtureZOrder()
        guard let sBefore = before.firstIndex(of: sentinelID), let bBefore = before.firstIndex(of: otherID), sBefore < bBefore,
              let target = await fresh(pid, firstID) else {
            record("single-window-other-display-z-order", "blocked", evidence: ["reason": "Could not establish sentinel above fixture B", "before": before.map(String.init).joined(separator: ",")])
            return
        }
        let focused = await act(.focus, on: target)
        let exact = await wait { self.focusedWindowID(pid: pid) == firstID }
        try? await Task.sleep(for: .milliseconds(200))
        let after = fixtureZOrder()
        let unchanged = after.firstIndex(of: sentinelID).flatMap { s in after.firstIndex(of: otherID).map { s < $0 } } == true
        var evidence = focusObservation(pid: pid)
        evidence.merge(await service.focusDiagnostics(), uniquingKeysWith: { _, new in new })
        evidence.merge([
            "targetID": "\(firstID)", "otherDisplayWindowID": "\(otherID)", "sentinelID": "\(sentinelID)",
            "accepted": "\(focused)", "exactObserved": "\(exact)", "otherDisplayOrderPreserved": "\(unchanged)",
            "sentinelAccepted": "\(sentinelAccepted)", "sentinelExactObserved": "\(sentinelExact)",
            "before": before.map(String.init).joined(separator: ","), "after": after.map(String.init).joined(separator: ",")], uniquingKeysWith: { _, new in new })
        record("single-window-other-display-z-order", focused && exact && unchanged ? "passed" : "failed", evidence: evidence)
        if ProcessInfo.processInfo.arguments.contains("--focus-stress"), focused && exact && unchanged {
            var passed = 0
            for _ in 0..<12 {
                guard isAllowed(pid), isAllowed(sentinelPID), let target = await fresh(pid, firstID) else { break }
                let s = await act(.focus, on: sentinel, using: sentinelService)
                let sExact = await wait { self.focusedWindowID(pid: sentinelPID) == sentinelID }
                let a = await act(.focus, on: target)
                let aExact = await wait { self.focusedWindowID(pid: pid) == firstID }
                let order = fixtureZOrder()
                let preserved = order.firstIndex(of: sentinelID).flatMap { s in order.firstIndex(of: otherID).map { s < $0 } } == true
                guard s && sExact && a && aExact && preserved else { break }
                passed += 1
            }
            var repeated = await service.focusDiagnostics()
            repeated["cycles"] = "\(passed)"; repeated["requiredCycles"] = "12"
            record("repeated-exact-focus-and-other-display-order", passed == 12 ? "passed" : "failed", evidence: repeated)
        }
    }

    private func verifyMinimize(pid: Int32, windowID: UInt32) async {
        guard let item = await fresh(pid, windowID) else { record("minimize-round-trip", "failed"); return }
        let accepted = await act(.minimize, on: item)
        let minimized = await waitAsync { (await self.fresh(pid, windowID))?.isMinimized == true }
        var filteredQuery = query(pid: pid)
        filteredQuery.includeMinimized = false
        let excludesMinimized = !(await service.discover(filteredQuery)).contains(where: { $0.windowID == windowID })
        let restoredItem = await fresh(pid, windowID)
        let restoredAction = if let restoredItem { await act(.minimize, on: restoredItem) } else { false }
        let restored = await waitAsync { (await self.fresh(pid, windowID))?.isMinimized == false }
        record("minimize-round-trip", accepted && minimized && excludesMinimized && restoredAction && restored ? "passed" : "failed",
               evidence: ["minimized": "\(minimized)", "filterExcludes": "\(excludesMinimized)", "restored": "\(restored)"])
    }

    private func verifyFullscreen(pid: Int32, windowID: UInt32) async {
        guard let item = await fresh(pid, windowID), !item.isFullscreen else {
            record("native-fullscreen-round-trip", "blocked", evidence: ["reason": "Fixture missing or already fullscreen"])
            return
        }
        _ = await act(.focus, on: item)
        let accepted = await act(.toggleFullscreen, on: item)
        let entered = await waitAsync(attempts: 80) { (await self.fresh(pid, windowID))?.isFullscreen == true }
        // Always restore our own window, even when the entry assertion failed.
        var current = await fresh(pid, windowID)
        if current == nil {
            current = (await discover(pid)).first(where: { $0.title.hasPrefix("WSFixture_A") && $0.isFullscreen })
        }
        if let current, current.isFullscreen { _ = await act(.toggleFullscreen, on: current) }
        let restored = await waitAsync(attempts: 80) {
            let windows = await self.discover(pid)
            return windows.contains { ($0.windowID == windowID || $0.title.hasPrefix("WSFixture_A")) && !$0.isFullscreen }
        }
        record("native-fullscreen-round-trip", accepted && entered && restored ? "passed" : "failed",
               evidence: ["entered": "\(entered)", "restored": "\(restored)"])
    }

    private func verifySpaces(pid: Int32, windowID: UInt32) async {
        let requestedID = windowID
        guard let target = (await discover(pid)).first(where: { $0.windowID == requestedID || $0.title.hasPrefix("WSFixture_A") }),
              let windowID = target.windowID, compositorOwns(windowID: windowID, pid: pid) else {
            record("space-move-round-trip", "blocked", evidence: [
                "requestedWindowID": "\(requestedID)", "ownerVerified": "false",
                "reason": "No live CG window owned by the current fixture process"])
            return
        }
        let desktops = SpaceService.destinations()
        guard isAllowed(pid), let original = FixtureSpaceMembership.read(windowID), original.count == 1,
              let originalID = original.first, let destination = desktops.first(where: { $0.id != originalID }),
              desktops.contains(where: { $0.id == originalID }) else {
            record("space-move-round-trip", "blocked", evidence: [
                "requestedWindowID": "\(requestedID)", "actualWindowID": "\(windowID)", "ownerVerified": "true",
                "reason": "No verifiable second ordinary Space or unavailable private API"])
            return
        }
        let moved = await SpaceService.move(windowID: windowID, toOrdinal: destination.ordinal)
        let observed = FixtureSpaceMembership.read(windowID) == [destination.id]
        var evidence = SpaceService.diagnostics(windowID: windowID).reduce(into: [String: String]()) {
            $0["moveTrace.\($1.key)"] = $1.value
        }
        var restored = FixtureSpaceMembership.restore(windowID, original: original)
        if !restored, let originalDesktop = desktops.first(where: { $0.id == originalID }), isAllowed(pid) {
            let fallbackAccepted = await SpaceService.move(windowID: windowID, toOrdinal: originalDesktop.ordinal)
            restored = FixtureSpaceMembership.read(windowID) == original
            evidence["restoreFallbackCalled"] = "true"
            evidence["restoreFallbackAccepted"] = "\(fallbackAccepted)"
            for (key, value) in SpaceService.diagnostics(windowID: windowID) { evidence["restoreTrace.\(key)"] = value }
        }
        evidence.merge(["requestedWindowID": "\(requestedID)", "actualWindowID": "\(windowID)", "ownerVerified": "true",
                        "original": "\(originalID)", "temporary": "\(destination.id)",
                        "moved": "\(moved)", "observed": "\(observed)", "restored": "\(restored)"], uniquingKeysWith: { _, new in new })
        record("space-move-round-trip", moved && observed && restored ? "passed" : "failed", evidence: evidence)
    }

    private func query(pid: Int32) -> WindowQuery {
        var query = WindowQuery()
        query.mode = .currentApplication
        query.currentPID = pid
        query.includeMinimized = true
        query.includeHidden = true
        query.allScreens = true
        query.allSpaces = true
        query.ownPID = ProcessInfo.processInfo.processIdentifier
        return query
    }

    private func renderFixtureUI(_ windows: [WindowItem]) async {
        guard CGPreflightScreenCaptureAccess(), windows.allSatisfy({ isAllowed($0.pid) }) else {
            record("switcher-panel-render", "blocked", evidence: ["reason": "Screen capture or fixture identity unavailable"])
            return
        }
        let preferences = Preferences()
        let controller = SwitchController(preferences: preferences)
        let layout = controller.switcherLayout
        let factor = controller.preferredScreen()?.backingScaleFactor ?? 2
        let box = CGSize(width: (layout.itemSize.width - 18) * factor, height: (layout.itemSize.height - 40) * factor)
        var images: [UInt32: CGImage] = [:]
        var captureEvidence: [String: String] = [:]
        let captureProbe = ProcessInfo.processInfo.arguments.contains("--probe-capture")
        var captureSucceeded = 0
        var childCaptureSucceeded = false
        for item in windows {
            guard isAllowed(item.pid), let id = item.windowID else { continue }
            if captureProbe {
                var evidence = WSCaptureEvidence()
                if let image = WSCreateWindowPreview(id, box, 4, false, &evidence) {
                    images[id] = image
                    let pixels = image.dataProvider?.data
                    var colors: Set<UInt32> = []
                    var redPixels = 0
                    if let pixels, let pointer = CFDataGetBytePtr(pixels) {
                        let count = CFDataGetLength(pixels)
                        let step = max(4, (count / 512 / 4) * 4)
                        for offset in stride(from: 0, to: max(0, count - 3), by: step) {
                            var value: UInt32 = 0
                            memcpy(&value, pointer.advanced(by: offset), 4)
                            colors.insert(value)
                        }
                        for offset in stride(from: 0, to: max(0, count - 3), by: 4) {
                            if pointer[offset + 2] > 160 && pointer[offset + 1] < 130 && pointer[offset] < 130 && pointer[offset + 3] > 200 { redPixels += 1 }
                        }
                    }
                    if evidence.primaryImageReturned.boolValue && colors.count > 4 { captureSucceeded += 1 }
                    captureEvidence["sample\(captureSucceeded).distinctColors"] = "\(colors.count)"
                    captureEvidence["sample\(captureSucceeded).size"] = "\(image.width),\(image.height)"
                    captureEvidence["sample\(captureSucceeded).children"] = "\(evidence.composedChildren)"
                    captureEvidence["sample\(captureSucceeded).AXChildFallback"] = "\(evidence.usedAXChildFallback.boolValue)"
                    captureEvidence["sample\(captureSucceeded).redPixels"] = "\(redPixels)"
                    if item.title == "WSFixture_A", evidence.composedChildren > 0, redPixels > 10 { childCaptureSucceeded = true }
                }
                captureEvidence["symbolsAvailable"] = "\(evidence.symbolsAvailable.boolValue)"
                captureEvidence["primaryImageReturned"] = "\(evidence.primaryImageReturned.boolValue)"
            }
            if images[id] == nil { images[id] = await service.thumbnail(windowID: id, maxPixelSize: box) }
        }
        if captureProbe {
            captureEvidence["successfulFixtures"] = "\(captureSucceeded)"
            captureEvidence["screenPreflight"] = "\(CGPreflightScreenCaptureAccess())"
            record("window-capture-backend", captureSucceeded == windows.count ? "passed" : "blocked", evidence: captureEvidence)
            record("child-window-capture", childCaptureSucceeded ? "passed" : "failed", evidence: [
                "redFixtureChildComposited": "\(childCaptureSucceeded)",
                "childWasVisible": "\(windows.first.flatMap { state($0.pid)?["captureChildVisible"] as? Bool } ?? false)"])
        }
        controller.showFixturePreview(windows, images: images)
        try? await Task.sleep(for: .milliseconds(250))
        do {
            let path = "/tmp/codex-windowswitch/fixture-panel.png"
            try controller.renderDemo(to: path)
            let geometry = controller.switcherLayout
            record("switcher-panel-render", images.count == windows.count ? "passed" : "failed", evidence: [
                "image": path, "fixtureWindowCount": "\(windows.count)", "realThumbnailCount": "\(images.count)",
                "itemSize": "\(geometry.itemSize.width),\(geometry.itemSize.height)",
                "panelSize": "\(geometry.panelFrame.width),\(geometry.panelFrame.height)",
                "thumbnailBoxPixels": "\(box.width),\(box.height)"])
        } catch { record("switcher-panel-render", "failed", evidence: ["reason": "Cannot render fixture panel"] ) }
        controller.cancel()
    }
    private func verifyQuickSwitch(primaryPID: Int32, first: WindowItem, targets: [NSRunningApplication]) async {
        guard let screen = NSScreen.screens.first,
              let secondPID = targets.first(where: { $0.processIdentifier != primaryPID })?.processIdentifier,
              let second = (await sentinelService.discover(query(pid: secondPID))).first,
              let secondID = second.windowID, let firstID = first.windowID,
              isAllowed(primaryPID), isAllowed(secondPID),
              let element = SingleWindowActivation.element(pid: secondPID, windowID: secondID) else {
            record("quick-switch-setup", "blocked"); return
        }
        // Move only the session-owned sentinel to A's display. No user input or
        // pointer movement is posted, and the ordinary fixture cleanup removes it.
        var point = CGPoint(x: first.frame.minX + 40, y: first.frame.minY + 40)
        guard let position = AXValueCreate(.cgPoint, &point),
              AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, position) == .success else {
            record("quick-switch-setup", "failed"); return
        }
        let suite = "WindowSwitch.Verification.\(session)"
        guard let defaults = UserDefaults(suiteName: suite) else { return }
        let rule = WindowRule(bundleID: bundleID, titlePattern: "WSFixture_(B|C)")
        defaults.setVolatileDomain(["quickSwitchOnMouseScreen": true, "quickHoldDelay": 200.0, "allSpaces": true, "allScreens": true, "oneWindowPerApp": false,
            "windowRules": (try? JSONEncoder().encode([rule])) ?? Data(), "hoverPreview": false], forName: UserDefaults.argumentDomain)
        let controller = SwitchController(preferences: Preferences(defaults: defaults), windowScope: fixturePIDs,
            backgroundResources: { BackgroundResourceSnapshot(idleSeconds: 30, loadPerCore: 0, thermalSeverity: 0, lowPowerMode: false) })
        controller.prepareInterface()
        defer { controller.stopBackgroundPreloading(); controller.cancel(); defaults.removeVolatileDomain(forName: UserDefaults.argumentDomain); defaults.removePersistentDomain(forName: suite) }
        await controller.service.startBackgroundMaintenance()
        await controller.warmInterface()
        _ = await act(.focus, on: second, using: sentinelService)
        _ = await act(.focus, on: first)
        _ = await wait { self.focusedWindowID(pid: primaryPID) == firstID }
        var passed = 0
        var latencies: [Double] = []
        for index in 0..<20 {
            guard fixturePIDs.allSatisfy({ isAllowed($0) }) else { break }
            let start = Date()
            controller.begin(modifier: .maskAlternate, pointerScreen: screen)
            guard let release = CGEvent(source: nil) else { break }
            release.flags = []
            _ = controller.handle(type: .flagsChanged, event: release)
            await controller.waitForQuickSwitch()
            let expectedPID = index % 2 == 0 ? secondPID : primaryPID
            let expectedID = index % 2 == 0 ? secondID : firstID
            let observed = await wait { NSWorkspace.shared.frontmostApplication?.processIdentifier == expectedPID
                && self.focusedWindowID(pid: expectedPID) == expectedID }
            latencies.append(Date().timeIntervalSince(start) * 1000)
            guard observed, !controller.panelIsVisible, controller.thumbnails.isEmpty else { break }
            passed += 1
            if index == 1 { try? await Task.sleep(for: .seconds(3)) }
        }
        let captures = await controller.service.snapshotCaptureCount()
        record("quick-tap-two-processes-roundtrip", passed == 20 && captures == 0 ? "passed" : "failed",
            evidence: ["passedTaps": "\(passed)", "expectedTaps": "20", "snapshotCaptures": "\(captures)",
                       "panelNeverShown": "\(!controller.panelIsVisible)", "maxTapMS": "\(latencies.max() ?? 0)",
                       "meanTapMS": "\(latencies.reduce(0, +) / Double(max(1, latencies.count)))"]
                .merging(controller.lastQuickEvidence, uniquingKeysWith: { _, new in new }))
        var gaps: [Double] = []
        let ticker = Task {
            var previous = Date()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(8)) } catch { return }
                let now = Date(); gaps.append(now.timeIntervalSince(previous) * 1000); previous = now
            }
        }
        controller.begin(modifier: .maskAlternate, pointerScreen: screen)
        let shown = await wait { controller.panelIsVisible && !controller.loading }
        let ids = Set(controller.displayedWindows.compactMap(\.windowID))
        record("hold-retains-both-background-and-foreground", shown && ids.contains(firstID) && ids.contains(secondID) ? "passed" : "failed",
            evidence: ["containsA": "\(ids.contains(firstID))", "containsB": "\(ids.contains(secondID))", "windows": "\(ids.count)"])
        let previews = await wait { controller.thumbnails.count >= 2 }
        try? await Task.sleep(for: .milliseconds(200))
        let before = await controller.service.snapshotCaptureCount()
        let coldGaps = gaps
        gaps.removeAll()
        controller.cancel()
        controller.begin(modifier: .maskAlternate, pointerScreen: screen)
        _ = await wait { controller.panelIsVisible && !controller.loading }
        try? await Task.sleep(for: .milliseconds(500))
        let after = await controller.service.snapshotCaptureCount()
        ticker.cancel()
        let sortedGaps = gaps.sorted()
        let p95 = sortedGaps.isEmpty ? 0 : sortedGaps[min(sortedGaps.count - 1, Int(Double(sortedGaps.count) * 0.95))]
        record("static-previews-reused-between-popups", previews && before > 0 && before == after ? "passed" : "failed",
            evidence: ["initialCaptures": "\(before)", "capturesAfterReopen": "\(after)", "cachedImages": "\(controller.thumbnails.count)",
                       "mainActorProbeP95MS": "\(p95)", "mainActorProbeMaxMS": "\(gaps.max() ?? 0)",
                       "firstPopupProbeMaxMS": "\(coldGaps.max() ?? 0)",
                       "probeLimit": "8ms timer scheduling gaps, not a GPU frame-rate measurement"])
        controller.cancel()
        await verifyThumbnailQuality(controller, screen: screen, windowID: firstID)
        await verifyOneWindowPerApp(controller, primary: first, other: second, screen: screen)
        await verifyRecentWindowOrder(controller, primary: first, other: second, screen: screen)
        await verifyPerformanceOptions(controller, screen: screen, windowIDs: [firstID, secondID])
        await verifyDockFirstActivation(controller, primary: first, other: second, screen: screen)
        await verifyWindowlessProcessIsSkipped(controller, primary: first, other: second, screen: screen)
        await controller.service.stopBackgroundMaintenance()
    }

    private func verifyThumbnailQuality(_ source: SwitchController, screen: NSScreen, windowID: UInt32) async {
        let controller = SwitchController(preferences: source.preferences, windowScope: fixturePIDs,
            backgroundResources: { BackgroundResourceSnapshot(idleSeconds: 30, loadPerCore: 0, thermalSeverity: 0, lowPowerMode: false) })
        controller.prepareInterface()
        let quality = controller.preferences.previewQuality, size = controller.preferences.thumbnailSize
        defer { controller.cancel(); controller.preferences.previewQuality = quality; controller.preferences.thumbnailSize = size }
        func pixels() -> CGImage? { controller.thumbnails[windowID]?.cgImage(forProposedRect: nil, context: nil, hints: nil) }
        func save(_ image: CGImage, name: String) {
            let bitmap = NSBitmapImageRep(cgImage: image)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/codex-windowswitch/quality-\(name).png"))
        }
        controller.preferences.thumbnailSize = 320
        controller.preferences.previewQuality = 2
        controller.begin(modifier: .maskAlternate, pointerScreen: screen)
        _ = await wait { controller.panelIsVisible && !controller.loading }
        let lowReady = await wait { pixels().map { max($0.width, $0.height) <= 200 } == true }
        let low = pixels()
        if let low { save(low, name: "low") }
        controller.cancel()
        controller.preferences.previewQuality = 4
        controller.begin(modifier: .maskAlternate, pointerScreen: screen)
        _ = await wait { controller.panelIsVisible && !controller.loading }
        let highReady = await wait { pixels().map { max($0.width, $0.height) > 200 } == true }
        let high = pixels()
        if let high { save(high, name: "high") }
        let evidence = await controller.service.captureDiagnostics(windowID: windowID)
        record("high-quality-upgrades-low-resolution-cache", lowReady && highReady && (high?.width ?? 0) > (low?.width ?? 0) ? "passed" : "failed",
            evidence: evidence.merging(["lowPixels": "\(low?.width ?? 0)x\(low?.height ?? 0)", "highPixels": "\(high?.width ?? 0)x\(high?.height ?? 0)",
                "displayScale": "\(screen.backingScaleFactor)", "itemWidthPoints": "320"], uniquingKeysWith: { _, new in new }))
        try? await Task.sleep(for: .milliseconds(200))
        let before = await controller.service.snapshotCaptureCount()
        controller.cancel()
        controller.begin(modifier: .maskAlternate, pointerScreen: screen)
        _ = await wait { controller.panelIsVisible && !controller.loading }
        try? await Task.sleep(for: .milliseconds(350))
        let after = await controller.service.snapshotCaptureCount()
        record("high-quality-preview-reused-without-recapture", highReady && before == after ? "passed" : "failed",
               evidence: ["capturesBefore": "\(before)", "capturesAfter": "\(after)"])
        controller.cancel()

        let enabled = controller.preferences.backgroundPreloadEnabled, interval = controller.preferences.backgroundPreloadInterval
        let backgroundImages = controller.preferences.backgroundPreloadThumbnails
        let background = SwitchController(preferences: source.preferences, windowScope: fixturePIDs,
            backgroundResources: { BackgroundResourceSnapshot(idleSeconds: 30, loadPerCore: 0, thermalSeverity: 0, lowPowerMode: false) })
        background.prepareInterface()
        defer {
            background.stopBackgroundPreloading(); background.cancel()
            controller.preferences.backgroundPreloadEnabled = enabled
            controller.preferences.backgroundPreloadInterval = interval
            controller.preferences.backgroundPreloadThumbnails = backgroundImages
        }
        controller.preferences.backgroundPreloadEnabled = true
        controller.preferences.backgroundPreloadThumbnails = true
        controller.preferences.backgroundPreloadInterval = 1
        background.refreshBackgroundPreloading(permitted: true)
        let placeholders = await wait(pollMilliseconds: 150) { background.preloadedThumbnailCount >= 2 }
        background.stopBackgroundPreloading()
        background.begin(modifier: .maskAlternate, pointerScreen: screen)
        _ = await wait { background.panelIsVisible && !background.loading }
        let upgraded = await wait {
            background.thumbnails[windowID]?.cgImage(forProposedRect: nil, context: nil, hints: nil).map { max($0.width, $0.height) > 200 } == true
        }
        record("background-placeholder-upgrades-to-high-on-open", placeholders && upgraded ? "passed" : "failed")
    }

    private func verifyOneWindowPerApp(_ controller: SwitchController, primary: WindowItem, other: WindowItem, screen: NSScreen) async {
        let grouped = controller.preferences.oneWindowPerApp, rules = controller.preferences.windowRules
        defer { controller.cancel(); controller.preferences.oneWindowPerApp = grouped; controller.preferences.windowRules = rules }
        guard let third = (await discover(primary.pid)).first(where: { $0.title == "WSFixture_C" }) else { return }
        controller.preferences.windowRules = [WindowRule(bundleID: bundleID, titlePattern: "WSFixture_B")]
        controller.preferences.oneWindowPerApp = true
        _ = await controller.service.perform(.focus, on: primary)
        _ = await wait { self.focusedWindowID(pid: primary.pid) == primary.windowID }
        _ = await controller.service.perform(.focus, on: third)
        _ = await wait { self.focusedWindowID(pid: third.pid) == third.windowID }
        controller.begin(modifier: .maskAlternate, pointerScreen: screen)
        _ = await wait { controller.panelIsVisible && !controller.loading }
        let ids = controller.displayedWindows.map(\.id)
        record("one-window-per-app-keeps-most-recent", ids == [third.id] ? "passed" : "failed",
               evidence: ["actual": ids.joined(separator: ","), "expected": third.id])
        controller.cancel()
        controller.begin(modifier: .maskAlternate, pointerScreen: screen)
        if let release = CGEvent(source: nil) { release.flags = []; _ = controller.handle(type: .flagsChanged, event: release) }
        await controller.waitForQuickSwitch()
        record("grouped-quick-tap-skips-other-window-of-same-app", focusedWindowID(pid: third.pid) == third.windowID ? "passed" : "failed")
        controller.begin(mode: .currentApplication, modifier: .maskAlternate, pointerScreen: screen)
        _ = await wait { controller.panelIsVisible && !controller.loading }
        let sameAppIDs = Set(controller.displayedWindows.map(\.id))
        record("current-app-shortcut-retains-all-windows", sameAppIDs == Set([primary.id, third.id]) ? "passed" : "failed")
        controller.cancel()
        controller.preferences.oneWindowPerApp = false
        controller.begin(modifier: .maskAlternate, pointerScreen: screen)
        _ = await wait { controller.panelIsVisible && !controller.loading }
        record("disabling-app-grouping-restores-all-windows", Set(controller.displayedWindows.map(\.id)) == Set([primary.id, third.id, other.id]) ? "passed" : "failed")
    }

    private func verifyRecentWindowOrder(_ controller: SwitchController, primary: WindowItem, other: WindowItem, screen: NSScreen) async {
        guard let third = (await discover(primary.pid)).first(where: { $0.title == "WSFixture_C" }),
              let thirdID = third.windowID else { record("shared-window-recency", "blocked"); return }
        let rules = controller.preferences.windowRules
        controller.preferences.windowRules = [WindowRule(bundleID: bundleID, titlePattern: "WSFixture_B")]
        defer { controller.cancel(); controller.preferences.windowRules = rules }
        for item in [third, other, primary] {
            _ = await controller.service.perform(.focus, on: item)
            _ = await wait { self.focusedWindowID(pid: item.pid) == item.windowID }
        }
        _ = await wait { self.focusedWindowID(pid: primary.pid) == primary.windowID }
        controller.begin(modifier: .maskAlternate, pointerScreen: screen)
        if let release = CGEvent(source: nil) { release.flags = []; _ = controller.handle(type: .flagsChanged, event: release) }
        await controller.waitForQuickSwitch()
        _ = await wait { self.focusedWindowID(pid: other.pid) == other.windowID }
        controller.begin(modifier: .maskAlternate, pointerScreen: screen)
        let list = await wait { controller.panelIsVisible && !controller.loading }
        if list { controller.choose(third.id) }
        let selectedThird = await wait { self.focusedWindowID(pid: primary.pid) == thirdID }
        controller.begin(modifier: .maskAlternate, pointerScreen: screen)
        _ = await wait { controller.panelIsVisible && !controller.loading }
        let actual = Array(controller.displayedWindows.prefix(3).map(\.id))
        let expected = [third.id, other.id, primary.id]
        record("quick-and-held-share-recent-window-order", selectedThird && actual == expected ? "passed" : "failed",
               evidence: ["actual": actual.joined(separator: ","), "expected": expected.joined(separator: ",")])
        controller.cancel()

        var query = WindowQuery(); query.ownPID = ProcessInfo.processInfo.processIdentifier; query.allowedPIDs = fixturePIDs
        _ = await sentinelService.perform(.focus, on: primary)
        _ = await wait { self.focusedWindowID(pid: primary.pid) == primary.windowID }
        _ = await sentinelService.perform(.focus, on: third)
        let sameApp = await waitAsync { (await controller.service.discover(query, cachedOnly: true)).first?.windowID == thirdID }
        _ = await sentinelService.perform(.focus, on: other)
        let anotherApp = await waitAsync { (await controller.service.discover(query, cachedOnly: true)).first?.windowID == other.windowID }
        record("external-app-and-window-focus-update-recency", sameApp && anotherApp ? "passed" : "failed",
               evidence: ["sameApplicationWindow": "\(sameApp)", "otherApplication": "\(anotherApp)"])
    }

    private func verifyDockFirstActivation(_ controller: SwitchController, primary: WindowItem, other: WindowItem, screen: NSScreen) async {
        guard NSScreen.screens.count >= 2, let app = NSRunningApplication(processIdentifier: primary.pid),
              let otherID = other.windowID,
              let otherElement = SingleWindowActivation.element(pid: other.pid, windowID: otherID),
              let remote = (await discover(primary.pid)).first(where: { $0.title == "WSFixture_B" }), let remoteID = remote.windowID,
              let otherOriginal = (await sentinelService.discover(query(pid: other.pid))).first?.frame else {
            record("dock-first-click-states", "skipped", required: false); return
        }
        func move(_ point: CGPoint) -> Bool {
            var point = point
            guard let value = AXValueCreate(.cgPoint, &point) else { return false }
            return AXUIElementSetAttributeValue(otherElement, kAXPositionAttribute as CFString, value) == .success
        }
        guard move(remote.frame.origin) else { record("dock-first-click-states", "blocked"); return }
        defer { _ = move(otherOriginal.origin) }
        let dock = DockFocusController(service: controller.service)
        for state in ["background", "foreground", "hidden", "minimized"] {
            _ = await controller.service.perform(.focus, on: primary)
            _ = await wait { self.focusedWindowID(pid: primary.pid) == primary.windowID }
            if state == "hidden" { _ = app.hide(); _ = await wait { app.isHidden } }
            if state == "minimized" {
                let local = (await discover(primary.pid)).filter { $0.title == "WSFixture_A" || $0.title == "WSFixture_C" }
                for item in local { _ = await act(.minimize, on: item) }
            }
            if state != "foreground" {
                _ = await sentinelService.perform(.focus, on: other)
                _ = await wait { self.focusedWindowID(pid: other.pid) == otherID }
                _ = await wait {
                    let order = self.fixtureZOrder()
                    return order.firstIndex(of: otherID).flatMap { s in order.firstIndex(of: remoteID).map { s < $0 } } ?? (state == "hidden")
                }
            }
            let before = fixtureZOrder()
            let baseline = before.firstIndex(of: otherID).flatMap { s in before.firstIndex(of: remoteID).map { s < $0 } } ?? (state == "hidden")
            let accepted = await dock.focus(application: app, on: screen)
            let focused = await wait { NSWorkspace.shared.frontmostApplication?.processIdentifier == primary.pid
                && self.rawFocusedWindowID(pid: primary.pid) != nil }
            let currentID = rawFocusedWindowID(pid: primary.pid)
            let local = (await discover(primary.pid)).first { $0.windowID == currentID }
            let onTarget = local.map { self.displayAreas()[0].whole.intersects($0.frame) && !$0.isMinimized } ?? false
            let after = fixtureZOrder()
            let preserved = after.firstIndex(of: otherID).flatMap { s in after.firstIndex(of: remoteID).map { s < $0 } } == true
            record("dock-one-activation-\(state)", accepted && focused && onTarget && baseline && preserved ? "passed" : "failed",
                evidence: ["activationCalls": "1", "accepted": "\(accepted)", "focused": "\(focused)", "onTargetDisplay": "\(onTarget)",
                           "baselineOtherDisplay": "\(baseline)", "otherDisplayOrderPreserved": "\(preserved)",
                           "before": before.map(String.init).joined(separator: ","), "after": after.map(String.init).joined(separator: ",")])
            if state == "minimized" {
                for item in await discover(primary.pid) where item.isMinimized { _ = await act(.focus, on: item) }
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--dock-input") {
            await verifyNativeDockClick(dock, primary: primary, other: other, remoteID: remoteID, screen: screen)
        }
    }

    /// Explicit opt-in: post one click only after hit-testing the exact session
    /// fixture URL in the real Dock. No other application icon can be clicked.
    private func verifyNativeDockClick(_ dock: DockFocusController, primary: WindowItem, other: WindowItem,
                                       remoteID: UInt32, screen: NSScreen) async {
        guard isAllowed(primary.pid), isAllowed(other.pid),
              let dockPID = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.dock" })?.processIdentifier,
              InputHookPolicy.permitsDockClicks(runningApplicationNames: Set(NSWorkspace.shared.runningApplications.compactMap { $0.executableURL?.lastPathComponent })) else {
            record("dock-native-single-click", "blocked", required: false); return
        }
        let dockRoot = AXUIElementCreateApplication(dockPID)
        AXUIElementSetMessagingTimeout(dockRoot, 0.03)
        func matches(_ element: AXUIElement) -> Bool {
            guard DockAX.value(element, kAXSubroleAttribute) as? String == "AXApplicationDockItem",
                  let url = DockAX.value(element, kAXURLAttribute) as? URL else { return false }
            return url.standardizedFileURL.resolvingSymlinksInPath().path == fixturePath
        }
        func icon() -> AXUIElement? {
            var nodes = [dockRoot]
            for _ in 0..<4 {
                var next: [AXUIElement] = []
                for element in nodes.prefix(100) {
                    AXUIElementSetMessagingTimeout(element, 0.02)
                    if matches(element) { return element }
                    next += DockAX.value(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
                }
                nodes = next
            }
            return nil
        }
        func move(_ point: CGPoint) {
            guard let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else { return }
            event.setIntegerValueField(.eventSourceUserData, value: WindowService.syntheticEventMarker)
            event.post(tap: .cghidEventTap)
        }
        let originalPointer = CGEvent(source: nil)?.location
        var lastPoint: CGPoint?
        defer {
            dock.stop()
            if let originalPointer, let lastPoint, let current = CGEvent(source: nil)?.location,
               hypot(current.x - lastPoint.x, current.y - lastPoint.y) < 5 { move(originalPointer) }
        }
        _ = await controllerFocusForDock(primary)
        _ = await sentinelService.perform(.focus, on: other)
        _ = await wait { self.focusedWindowID(pid: other.pid) == other.windowID }
        guard dock.start() else { record("dock-native-single-click", "blocked", required: false); return }
        let height = CGDisplayBounds(CGMainDisplayID()).height
        let area = CGRect(x: screen.frame.minX, y: height - screen.frame.maxY, width: screen.frame.width, height: screen.frame.height)
        let orientation = UserDefaults.standard.persistentDomain(forName: "com.apple.dock")?["orientation"] as? String ?? "bottom"
        let edge = orientation == "left" ? CGPoint(x: area.minX + 1, y: area.midY)
            : orientation == "right" ? CGPoint(x: area.maxX - 1, y: area.midY) : CGPoint(x: area.midX, y: area.maxY - 1)
        move(edge); lastPoint = edge
        try? await Task.sleep(for: .milliseconds(900))
        guard let item = icon(), let bounds = DockAX.frame(item) else {
            record("dock-native-single-click", "blocked", required: false, evidence: ["reason": "Session fixture icon not exposed by Dock"]); return
        }
        var point = CGPoint(x: bounds.midX, y: bounds.midY)
        move(point); lastPoint = point
        try? await Task.sleep(for: .milliseconds(200))
        if let updated = DockAX.frame(item) { point = CGPoint(x: updated.midX, y: updated.midY) }
        guard area.contains(point) else { record("dock-native-single-click", "blocked", required: false); return }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.04)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
              var current = hit else { record("dock-native-single-click", "blocked", required: false); return }
        var safe = false
        for _ in 0..<4 {
            if matches(current) { safe = true; break }
            guard let parent = DockAX.value(current, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            current = unsafeDowncast(parent, to: AXUIElement.self)
        }
        guard safe else { record("dock-native-single-click", "blocked", required: false, evidence: ["reason": "Hit test did not match the fixture URL"]); return }
        move(point); lastPoint = point
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { return }
            event.flags = []; event.setIntegerValueField(.mouseEventClickState, value: 1)
            event.setIntegerValueField(.eventSourceUserData, value: WindowService.syntheticEventMarker)
            event.post(tap: .cghidEventTap)
            if type == .leftMouseDown { try? await Task.sleep(for: .milliseconds(60)) }
        }
        let focused = await wait { self.focusedWindowID(pid: primary.pid) == primary.windowID }
        let order = fixtureZOrder()
        let preserved = other.windowID.flatMap { order.firstIndex(of: $0) }.flatMap { s in order.firstIndex(of: remoteID).map { s < $0 } } == true
        record("dock-native-single-click", focused && preserved ? "passed" : "failed",
               evidence: ["postedClicks": "1", "exactWindowFocused": "\(focused)", "otherDisplayPreserved": "\(preserved)"])
    }

    private func controllerFocusForDock(_ item: WindowItem) async -> Bool {
        await act(.focus, on: item)
    }

    private func verifyWindowlessProcessIsSkipped(_ controller: SwitchController, primary: WindowItem,
                                                  other: WindowItem, screen: NSScreen) async {
        guard isAllowed(primary.pid), isAllowed(other.pid), let otherID = other.windowID else { return }
        controller.preferences.windowRules = [WindowRule(bundleID: bundleID, titlePattern: "WSFixture_B")]
        _ = await act(.focus, on: primary)
        _ = await act(.focus, on: other, using: sentinelService)
        _ = await wait { self.focusedWindowID(pid: other.pid) == otherID }
        let closed = await act(.close, on: other, using: sentinelService)
        let gone = await waitAsync { (await self.sentinelService.discover(self.query(pid: other.pid))).isEmpty }
        let stillRunning = NSRunningApplication(processIdentifier: other.pid)?.isTerminated == false
        _ = await act(.focus, on: primary)
        let before = rawFocusedWindowID(pid: primary.pid)
        controller.begin(modifier: .maskAlternate, pointerScreen: screen)
        if let release = CGEvent(source: nil) { release.flags = []; _ = controller.handle(type: .flagsChanged, event: release) }
        await controller.waitForQuickSwitch()
        let switched = await wait { NSWorkspace.shared.frontmostApplication?.processIdentifier == primary.pid
            && self.rawFocusedWindowID(pid: primary.pid) != before }
        record("quick-skips-app-after-last-window-close", closed && gone && stillRunning && switched ? "passed" : "failed",
            evidence: ["closed": "\(closed)", "AXWindowsEmpty": "\(gone)", "processStillRunning": "\(stillRunning)",
                       "switchedToAnotherLiveWindow": "\(switched)"])
        controller.begin(modifier: .maskAlternate, pointerScreen: screen)
        let shown = await wait { controller.panelIsVisible && !controller.loading }
        let absent = !controller.displayedWindows.contains { $0.pid == other.pid }
        record("windowless-process-absent-from-window-list", shown && absent && stillRunning ? "passed" : "failed",
            evidence: ["processStillRunning": "\(stillRunning)", "absent": "\(absent)"])
        controller.cancel()
    }

    private func verifyPerformanceOptions(_ controller: SwitchController, screen: NSScreen, windowIDs: [UInt32]) async {
        let foregroundImages = controller.thumbnails
        _ = await wait { !controller.panelIsVisible }
        controller.preferences.fadeInDuration = 150
        controller.preferences.fadeOutDuration = 150
        controller.begin(modifier: .maskAlternate, pointerScreen: screen)
        _ = await wait(pollMilliseconds: 10) { controller.panelIsVisible }
        let initialAlpha = controller.panelAlpha
        let fadedIn = await wait(pollMilliseconds: 10) { controller.panelAlpha >= 0.99 }
        let fadeStart = Date()
        controller.cancel()
        let hidden = await wait(pollMilliseconds: 10) { !controller.panelIsVisible }
        let fadeMS = Date().timeIntervalSince(fadeStart) * 1000
        record("configurable-fade-durations", fadedIn && initialAlpha < 1 && hidden && fadeMS >= 135 && fadeMS < 400 ? "passed" : "failed",
               evidence: ["configuredInMS": "150", "configuredOutMS": "150", "initialAlpha": "\(initialAlpha)", "observedOutMS": "\(fadeMS)", "pollIntervalMS": "10"])
        controller.preferences.fadeInDuration = 0; controller.preferences.fadeOutDuration = 0
        controller.begin(modifier: .maskAlternate, pointerScreen: screen)
        _ = await wait { controller.panelIsVisible }
        let instantIn = controller.panelAlpha == 1
        controller.cancel()
        record("zero-duration-is-immediate", instantIn && !controller.panelIsVisible ? "passed" : "failed")

        controller.preferences.backgroundPreloadEnabled = true
        controller.preferences.backgroundPreloadInterval = 1
        controller.preferences.backgroundPreloadThumbnails = false
        let beforeMetadata = await controller.service.snapshotCaptureCount()
        controller.refreshBackgroundPreloading(permitted: true)
        let metadata = await wait { controller.preloadedWindowCount >= 2 }
        let afterMetadata = await controller.service.snapshotCaptureCount()
        record("background-metadata-without-screenshots", metadata && beforeMetadata == afterMetadata ? "passed" : "failed",
               evidence: ["cachedWindows": "\(controller.preloadedWindowCount)", "newCaptures": "\(afterMetadata - beforeMetadata)"])

        controller.preferences.backgroundPreloadThumbnails = true
        controller.refreshBackgroundPreloading(permitted: true)
        let cached = await wait(pollMilliseconds: 150) { controller.preloadedThumbnailCount >= 2 }
        let backgroundEvidence = await controller.service.captureDiagnostics(windowID: windowIDs[0])
        record("background-previews-at-lowest-priority", cached && backgroundEvidence["taskPriority"] == "\(TaskPriority.background.rawValue)" ? "passed" : "failed",
               evidence: backgroundEvidence.merging(["cachedImages": "\(controller.preloadedThumbnailCount)", "intervalSeconds": "1"], uniquingKeysWith: { _, new in new }))

        let firstCycleCount = await controller.service.snapshotCaptureCount()
        let repeated = await waitAsync(attempts: 120) { await controller.service.snapshotCaptureCount() > firstCycleCount }
        let secondCycleCount = await controller.service.snapshotCaptureCount()
        record("background-refreshes-on-custom-interval", repeated ? "passed" : "failed",
               evidence: ["intervalSeconds": "1", "firstCycleCaptures": "\(firstCycleCount)", "laterCaptures": "\(secondCycleCount)"])

        controller.active = true
        try? await Task.sleep(for: .milliseconds(200))
        let beforePause = await controller.service.snapshotCaptureCount()
        try? await Task.sleep(for: .milliseconds(1200))
        let afterPause = await controller.service.snapshotCaptureCount()
        record("background-pauses-while-switching", beforePause == afterPause ? "passed" : "failed",
               evidence: ["before": "\(beforePause)", "after": "\(afterPause)"])
        controller.active = false
        controller.begin(modifier: .maskAlternate, pointerScreen: screen)
        let visible = await wait { controller.panelIsVisible && !controller.loading }
        let fromMemory = windowIDs.allSatisfy { controller.thumbnails[$0] != nil }
        try? await Task.sleep(for: .milliseconds(150))
        let afterOpen = await controller.service.snapshotCaptureCount()
        record("background-cache-used-on-open", visible && fromMemory && afterOpen == afterPause ? "passed" : "failed",
               evidence: ["imagesAlreadyPresent": "\(fromMemory)", "newCaptures": "\(afterOpen - afterPause)"])
        record("background-cache-does-not-downgrade-high-quality", windowIDs.allSatisfy { controller.thumbnails[$0] === foregroundImages[$0] } ? "passed" : "failed")
        controller.cancel()
        controller.preferences.backgroundPreloadEnabled = false
        controller.refreshBackgroundPreloading(permitted: true)
        try? await Task.sleep(for: .milliseconds(200))
        let beforeDisable = await controller.service.snapshotCaptureCount()
        try? await Task.sleep(for: .milliseconds(1200))
        let afterDisable = await controller.service.snapshotCaptureCount()
        record("background-disabled-stops-refresh", beforeDisable == afterDisable ? "passed" : "failed",
               evidence: ["before": "\(beforeDisable)", "after": "\(afterDisable)"])
    }

    private func discover(_ pid: Int32) async -> [WindowItem] {
        guard isAllowed(pid) else { return [] }
        return await service.discover(query(pid: pid)).filter { $0.pid == pid && $0.bundleID == bundleID }
    }
    private func fresh(_ pid: Int32, _ windowID: UInt32) async -> WindowItem? {
        (await discover(pid)).first { $0.windowID == windowID }
    }
    private func act(_ action: WindowAction, on item: WindowItem, using targetService: WindowService? = nil) async -> Bool {
        guard item.bundleID == bundleID, isAllowed(item.pid), item.documentURL == nil else { return false }
        return await (targetService ?? service).perform(action, on: item)
    }
    private func matches(_ app: NSRunningApplication) -> Bool {
        guard app.bundleIdentifier == bundleID, !app.isTerminated,
              app.bundleURL?.standardizedFileURL.resolvingSymlinksInPath().path == fixturePath,
              let state = state(app.processIdentifier) else { return false }
        return state["session"] as? String == session && state["bundleID"] as? String == bundleID
            && (state["pid"] as? NSNumber)?.int32Value == app.processIdentifier
    }
    private func isAllowed(_ pid: Int32) -> Bool {
        fixturePIDs.contains(pid) && NSRunningApplication(processIdentifier: pid).map(matches) == true
    }
    private func state(_ pid: Int32) -> [String: Any]? {
        let url = URL(fileURLWithPath: "/tmp/codex-windowswitch/fixture-state-\(pid).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    private func actionCount(_ name: String, pid: Int32) -> Int {
        ((state(pid)?["actionCounts"] as? [String: NSNumber])?[name])?.intValue ?? 0
    }
    private func focusedWindowID(pid: Int32) -> UInt32? {
        guard isAllowed(pid), NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return nil }
        return rawFocusedWindowID(pid: pid)
    }
    private func rawFocusedWindowID(pid: Int32) -> UInt32? {
        guard isAllowed(pid) else { return nil }
        let root = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(root, 0.12)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(root, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return SingleWindowActivation.windowID(for: unsafeDowncast(value, to: AXUIElement.self))
    }
    private func focusObservation(pid: Int32) -> [String: String] {
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var evidence = ["expectedPID": "\(pid)", "frontmostMatches": "\(frontPID == pid)",
                        "frontmostPID": frontPID.map { fixturePIDs.contains($0) ? String($0) : "non-fixture" } ?? "none",
                        "rawAXFocusedWindowID": rawFocusedWindowID(pid: pid).map(String.init) ?? "none"]
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.12)
        var application: CFTypeRef?
        let applicationCode = AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &application)
        evidence["systemFocusedApplicationAXCode"] = "\(applicationCode.rawValue)"
        if let application, CFGetTypeID(application) == AXUIElementGetTypeID() {
            let element = unsafeDowncast(application, to: AXUIElement.self)
            var systemPID: Int32 = 0
            AXUIElementGetPid(element, &systemPID)
            evidence["systemFocusedPID"] = fixturePIDs.contains(systemPID) ? "\(systemPID)" : "non-fixture"
            evidence["systemFocusedMatches"] = "\(systemPID == pid)"
            if fixturePIDs.contains(systemPID) {
                evidence["systemAXFocusedWindowID"] = rawFocusedWindowID(pid: systemPID).map(String.init) ?? "none"
            }
        }
        return evidence
    }
    private func fixtureZOrder() -> [UInt32] {
        let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let pid = row[kCGWindowOwnerPID as String] as? Int32, fixturePIDs.contains(pid),
                  row[kCGWindowLayer as String] as? Int == 0 else { return nil }
            return row[kCGWindowNumber as String] as? UInt32
        }
    }
    private func compositorOwns(windowID: UInt32, pid: Int32) -> Bool {
        guard isAllowed(pid) else { return false }
        let rows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
        return rows.contains {
            $0[kCGWindowNumber as String] as? UInt32 == windowID && $0[kCGWindowOwnerPID as String] as? Int32 == pid
        }
    }
    private func displayAreas() -> [(whole: CGRect, visible: CGRect)] {
        let top = CGDisplayBounds(CGMainDisplayID()).height
        return NSScreen.screens.map {
            let whole = $0.frame, visible = $0.visibleFrame
            return (CGRect(x: whole.minX, y: top - whole.maxY, width: whole.width, height: whole.height),
                    CGRect(x: visible.minX, y: top - visible.maxY, width: visible.width, height: visible.height))
        }
    }
    private func visibleArea(for frame: CGRect) -> CGRect? {
        displayAreas().max { a, b in
            let lhs = frame.intersection(a.whole), rhs = frame.intersection(b.whole)
            return (lhs.isNull ? 0 : lhs.width * lhs.height) < (rhs.isNull ? 0 : rhs.width * rhs.height)
        }?.visible
    }
    private func expectedFrame(_ action: WindowAction, current: CGRect, area: CGRect) -> CGRect {
        switch action {
        case .center:
            let width = min(current.width, area.width), height = min(current.height, area.height)
            return CGRect(x: area.midX - width / 2, y: area.midY - height / 2, width: width, height: height)
        case .snapLeft: return CGRect(x: area.minX, y: area.minY, width: area.width / 2, height: area.height)
        case .snapRight: return CGRect(x: area.midX, y: area.minY, width: area.width / 2, height: area.height)
        case .compact: return CGRect(x: area.minX + area.width / 6, y: area.minY + area.height / 8, width: area.width * 2 / 3, height: area.height * 3 / 4)
        default: return area
        }
    }
    private func wait(pollMilliseconds: Int = 75, _ condition: () -> Bool) async -> Bool {
        for _ in 0..<max(40, 3000 / max(1, pollMilliseconds)) {
            if condition() { return true }
            do { try await Task.sleep(for: .milliseconds(pollMilliseconds)) } catch { return false }
        }
        return condition()
    }
    private func waitForStableFixtureFront(pid: Int32) async -> Bool {
        var stableSince: ContinuousClock.Instant?
        for _ in 0..<100 {
            let now = ContinuousClock.now
            if focusedWindowID(pid: pid) != nil {
                if let since = stableSince, now - since >= .milliseconds(250) { return true }
                if stableSince == nil { stableSince = now }
            } else { stableSince = nil }
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return false }
        }
        return false
    }
    private func waitAsync(attempts: Int = 40, _ condition: () async -> Bool) async -> Bool {
        for _ in 0..<attempts {
            if await condition() { return true }
            do { try await Task.sleep(for: .milliseconds(75)) } catch { return false }
        }
        return await condition()
    }
    private func waitFrame(pid: Int32, windowID: UInt32, expected: CGRect) async -> Bool {
        await waitAsync {
            guard let actual = await self.fresh(pid, windowID) else { return false }
            return abs(actual.frame.minX - expected.minX) <= 3 && abs(actual.frame.minY - expected.minY) <= 3
                && abs(actual.frame.width - expected.width) <= 3 && abs(actual.frame.height - expected.height) <= 3
        }
    }
    private func describe(_ frame: CGRect?) -> String {
        guard let frame else { return "missing" }
        return [frame.minX, frame.minY, frame.width, frame.height].map { String(format: "%.1f", $0) }.joined(separator: ",")
    }
    private func record(_ name: String, _ status: String, required: Bool = true, evidence: [String: String] = [:]) {
        checks.append(FunctionalCheck(name: name, status: status, required: required, evidence: evidence))
    }
    private func cleanup() {
        for pid in fixturePIDs where isAllowed(pid) { _ = NSRunningApplication(processIdentifier: pid)?.terminate() }
    }
    private func writeReport() {
        let status: String
        if checks.contains(where: { $0.required && $0.status == "failed" }) { status = "failed" }
        else if checks.contains(where: { $0.required && $0.status == "blocked" }) { status = "blocked" }
        else { status = "passed" }
        let report = FunctionalReport(version: 1, status: status, session: session,
            accessibility: AXIsProcessTrusted(), screenCapture: CGPreflightScreenCaptureAccess(),
            displayCount: NSScreen.screens.count, fixturePIDs: fixturePIDs.sorted(), checks: checks)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let directory = URL(fileURLWithPath: "/tmp/codex-windowswitch", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let filename = ProcessInfo.processInfo.arguments.contains("--render-ui") ? "ui-functional-report.json" : "functional-report.json"
            try encoder.encode(report).write(to: directory.appendingPathComponent(filename), options: .atomic)
            print("FUNCTIONAL_REPORT /tmp/codex-windowswitch/\(filename) status=\(status)")
        } catch {
            print("FUNCTIONAL_REPORT_WRITE_FAILED \(error.localizedDescription)")
        }
    }
}

/// Extended Space tests can restore even a partially changed membership. The
/// caller only supplies a verified disposable fixture window ID.
private nonisolated enum FixtureSpaceMembership {
    private typealias Connection = @convention(c) () -> UInt32
    private typealias Copy = @convention(c) (UInt32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias Change = @convention(c) (UInt32, CFArray, CFArray) -> Void
    private struct API: @unchecked Sendable {
        let connection: Connection
        let copy: Copy
        let add: Change
        let remove: Change
    }
    private static let api: API? = {
        guard let image = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL) else { return nil }
        func symbol<T>(_ name: String, as: T.Type) -> T? { dlsym(image, name).map { unsafeBitCast($0, to: T.self) } }
        guard let connection = symbol("SLSMainConnectionID", as: Connection.self),
              let copy = symbol("SLSCopySpacesForWindows", as: Copy.self),
              let add = symbol("SLSAddWindowsToSpaces", as: Change.self),
              let remove = symbol("SLSRemoveWindowsFromSpaces", as: Change.self) else { dlclose(image); return nil }
        return API(connection: connection, copy: copy, add: add, remove: remove)
    }()
    static func read(_ windowID: UInt32) -> Set<UInt64>? {
        guard let api, let array = api.copy(api.connection(), 7, [NSNumber(value: windowID)] as CFArray)?.takeRetainedValue() else { return nil }
        return Set((array as NSArray).compactMap { ($0 as? NSNumber)?.uint64Value })
    }
    static func restore(_ windowID: UInt32, original: Set<UInt64>) -> Bool {
        guard let api else { return false }
        let windows = [NSNumber(value: windowID)] as CFArray
        api.add(api.connection(), windows, original.map { NSNumber(value: $0) } as CFArray)
        guard let now = read(windowID), original.isSubset(of: now) else { return false }
        let extras = now.subtracting(original)
        if !extras.isEmpty { api.remove(api.connection(), windows, extras.map { NSNumber(value: $0) } as CFArray) }
        return read(windowID) == original
    }
}
