import AppKit
import Observation
import SwiftUI
import QuartzCore
import WindowSwitchCore
import os

private let switchLog = Logger(subsystem: "io.github.morefreefg.WindowSwitch", category: "switcher")
private func describe(_ windows: [WindowItem]) -> String {
    windows.map { "\($0.appName)#\($0.windowID.map(String.init) ?? "-")" }.joined(separator: ", ")
}

@Observable final class SwitchController {
    let preferences: Preferences
    let service = WindowService()
    private let windowScope: Set<Int32>?
    private let backgroundResources: @Sendable () -> BackgroundResourceSnapshot
    var selection = SwitchSelection()
    var applicationWindows = SwitchSelection()
    var searching = false
    var browsingApplicationWindows = false
    var thumbnails: [UInt32: NSImage] = [:]
    var spaceNumbers: [UInt32: Int] = [:]
    var active = false
    var loading = false
    var expanded = false
    var mode: SwitchMode = .windows
    private(set) var nativeSession = false
    var message = ""
    var onSettings: (() -> Void)?
    var onRecentDocuments: ((String?) -> Void)?
    private var panel: SwitchPanel?
    private var heldModifier: CGEventFlags = []
    private var session = UUID()
    private var pendingSteps = 0
    private var commitWhenLoaded = false
    private var suppressedKeys: Set<Int64> = []
    private var work: Task<Void, Never>?
    private var previewWork: Task<Void, Never>?
    private var displayWork: Task<Void, Never>?
    private var startingPID: Int32?
    private var applicationWork: Task<Void, Never>?
    private var hoverWork: Task<Void, Never>?
    private var fullPreview: NSPanel?
    private var actionWork: Task<Void, Never>?
    private var autoActivateWork: Task<Void, Never>?
    private var lastScrollAction = Date.distantPast
    private var mouseAtOpen = CGPoint.zero
    private var mouseSelectionEnabled = false
    private var dismissalWork: Task<Void, Never>?
    private var inventoryWork: Task<Void, Never>?
    private var cumulativeMouseDistance: CGFloat = 0
    private var displayDelayElapsed = false
    private var quickGesture = false
    private var quickQuery: WindowQuery?
    private var quickScreenBounds = CGRect.zero
    private var quickDisplayBounds: [CGRect] = []
    private var quickFocusWork: Task<Void, Never>?
    private var previewStamps: [UInt32: ThumbnailStamp] = [:]
    private var previewDates: [UInt32: Date] = [:]
    private(set) var lastQuickEvidence: [String: String] = [:]
    @ObservationIgnored private var preloadWork: Task<Void, Never>?
    @ObservationIgnored private var preloadConfiguration: BackgroundPreloadConfiguration?
    @ObservationIgnored private var preloadToken = UUID()
    @ObservationIgnored private var preloadedThumbnails: [UInt32: PreloadedThumbnail] = [:]
    @ObservationIgnored private var preloadedWindows: [WindowItem] = []
    private var nativeListFrame: CGRect?
    private var sessionBegan = Date()
    private var nativeSelectedAppFrame: CGRect?

    var switcherLayout: SwitcherLayout {
        let screen = preferredScreen()
        let frame = screen?.frame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
        return SwitcherLayout(count: displayedWindows.count, preferredWidth: preferences.thumbnailSize,
                                      screenFrame: frame, visibleFrame: screen?.visibleFrame ?? frame,
                                      nativeListFrame: nativeSession ? nativeListFrame : nil,
                                      selectedApplicationFrame: nativeSession ? nativeSelectedAppFrame : nil)
    }
    private var thumbnailContentSize: CGSize {
        let size = switcherLayout.itemSize
        return CGSize(width: max(1, size.width - 18), height: max(1, size.height - 40))
    }
    private var thumbnailRequest: ThumbnailRequest {
        ThumbnailRequest(contentSize: thumbnailContentSize, backingScale: panel?.backingScaleFactor ?? preferredScreen()?.backingScaleFactor ?? 1,
                         quality: preferences.previewQuality)
    }
    /// The open switcher shows previews exactly as cached. It only fills a window that has no
    /// preview at all; existing previews are refreshed in the background while the panel is hidden.
    private func needsThumbnail(_ item: WindowItem, request: ThumbnailRequest) -> Bool {
        guard let id = item.windowID else { return false }
        return thumbnails[id] == nil
    }
    private func gridCapacity(_ items: [WindowItem]) -> [WindowItem] { Array(items.prefix(switcherLayout.capacity)) }
    private func listItems(_ windows: [WindowItem]) -> [WindowItem] {
        gridCapacity(preferences.oneWindowPerApp && mode == .windows ? WindowGrouping.onePerApplication(windows) : windows)
    }

    var displayedSelection: SwitchSelection { mode == .applications ? applicationWindows : selection }
    var chosenWindow: WindowItem? {
        mode == .applications && browsingApplicationWindows ? (applicationWindows.selected ?? selection.selected) : selection.selected
    }
    var displayedWindows: [WindowItem] { displayedSelection.filtered }

    init(preferences: Preferences, windowScope: Set<Int32>? = nil,
         backgroundResources: @escaping @Sendable () -> BackgroundResourceSnapshot = SystemBackgroundResources.snapshot) {
        self.preferences = preferences; self.windowScope = windowScope
        self.backgroundResources = backgroundResources
    }

    private func listQuery(screen: NSScreen?) -> WindowQuery {
        var query = preferences.query(mode: mode, currentPID: startingPID, screen: screen)
        query.allowedPIDs = windowScope
        return query
    }

    func handle(type: CGEventType, event: CGEvent) -> Bool {
        if event.getIntegerValueField(.eventSourceUserData) == WindowService.syntheticEventMarker { return false }
        if type == .leftMouseDown || type == .rightMouseDown {
            if active, let panel, !panel.frame.contains(NSEvent.mouseLocation) { cancel() }
            return false
        }
        if type == .scrollWheel, active, panel?.frame.contains(NSEvent.mouseLocation) == true {
            let delta = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
            if preferences.scrollWindowActions || event.flags.contains(.maskShift) {
                if delta != 0 && Date().timeIntervalSince(lastScrollAction) > 0.3 {
                    lastScrollAction = Date(); perform(delta > 0 ? .bringToCurrentSpace : .minimize)
                }
                return true
            }
            return false
        }
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyUp { return suppressedKeys.remove(key) != nil }
        if type == .flagsChanged {
            if active && !heldModifier.isEmpty && !event.flags.contains(heldModifier) {
                if nativeSession && !browsingApplicationWindows { cancel() } else { commit() }
            }
            return false
        }
        guard type == .keyDown else { return false }
        if !active && suppressedKeys.contains(key) { return true }
        let shiftHeld = event.flags.contains(.maskShift)
        let reverse = shiftHeld && preferences.reverseWithShift
        if active {
            if quickGesture && key != 53 { promoteQuickGesture() }
            if nativeSession && key == 48 { return false }
            if nativeSession && key == 53 { cancel(); return false }
            if nativeSession && !browsingApplicationWindows && (key == 123 || key == 124) { return false }
            switch key {
            case 48: advance(reverse ? -1 : 1)
            case 50, 10:
                if mode == .applications { moveWindow(reverse ? -1 : 1) }
                else if mode == .currentApplication { advance(reverse ? -1 : 1) }
                else { moveWindow(-1) }
            case 53: cancel()
            case 36, 76: commit()
            case 123:
                if shiftHeld { perform(.snapLeft) } else { moveWindow(-1) }
            case 124:
                if shiftHeld { perform(.snapRight) } else { moveWindow(1) }
            case 126:
                if shiftHeld {
                    if mode == .applications { browsingApplicationWindows = true }
                    perform(.maximize)
                }
                else if mode == .applications { browsingApplicationWindows = false; scheduleFullPreview() }
                else { moveRow(-1) }
            case 125:
                if shiftHeld { perform(mode == .applications && !browsingApplicationWindows ? .hideApplication : .compact) }
                else if mode == .applications { moveWindow(1) }
                else { moveRow(1) }
            case 49: perform(.bringToCurrentSpace)
            case 51, 117:
                if searching { editSearch(removing: true) } else { perform(.close) }
            case 84 where mode != .applications: perform(.minimize)
            case 86 where mode != .applications: perform(.snapLeft)
            case 88 where mode != .applications: perform(.snapRight)
            case 91 where mode != .applications: perform(.maximize)
            case 44: searching.toggle()
            default:
                let character = NSEvent(cgEvent: event)?.charactersIgnoringModifiers ?? ""
                if !searching {
                    switch character.lowercased() {
                    case "w": perform(.close)
                    case "m": perform(.minimize)
                    case "q": perform(mode == .applications && shiftHeld ? .forceQuitApplication : .quitApplication)
                    case "f": perform(.toggleFullscreen)
                    case "c": perform(.center)
                    case "n": perform(.newWindow)
                    case "t": perform(.newTab)
                    case "o" where mode == .applications: perform(.openFile)
                    case "h": if shiftHeld { perform(.hideApplication) } else { moveWindow(-1) }
                    case "l": moveWindow(1)
                    case "k": moveRow(-1)
                    case "j": moveRow(1)
                    case "p": cancel(); onSettings?()
                    case "r": cancel(); onRecentDocuments?(nil)
                    case "1"..."9" where mode == .applications:
                        if let number = Int(character), applicationWindows.filtered.indices.contains(number - 1) {
                            applicationWindows.select(applicationWindows.filtered[number - 1].id)
                            browsingApplicationWindows = true
                        }
                    case "1"..."9":
                        if let number = Int(character), let id = chosenWindow?.windowID {
                            let expectedSession = session
                            Task { [weak self] in
                                let moved = await SpaceService.move(windowID: id, toOrdinal: number)
                                guard let self, self.active, self.session == expectedSession else { return }
                                self.message = moved ? "已移到桌面 \(number)" : "无法移动到该桌面"
                                self.updatePanel()
                            }
                        }
                    default: break
                    }
                } else { appendSearch(character) }
            }
            suppressedKeys.insert(key)
            return true
        }
        guard preferences.enabled else { return false }
        let flags = event.flags.intersection([.maskCommand, .maskAlternate, .maskControl])
        let requested: SwitchMode?
        let modifier: ShortcutModifier
        if preferences.currentWindowEnabled && (key == 50 || key == 10) && flags == preferences.currentModifier.flag {
            requested = .currentApplication; modifier = preferences.currentModifier
        } else if preferences.allWindowsEnabled && key == 48 && flags == preferences.windowModifier.flag {
            requested = .windows; modifier = preferences.windowModifier
        } else if key == 48 && preferences.applicationSwitcher && flags == preferences.applicationModifier.flag {
            if preferences.nativeAppEnhancement && preferences.applicationModifier == .command { return false }
            requested = .applications; modifier = preferences.applicationModifier
        } else { return false }
        switchLog.debug("hotkey accepted mode=\(String(describing: requested), privacy: .public)")
        if let requested { begin(mode: requested, modifier: modifier.flag, reverse: reverse) }
        suppressedKeys.insert(key)
        return true
    }

    private func appendSearch(_ text: String) {
        if !text.isEmpty && text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
            if mode == .applications { applicationWindows.search += text }
            else { selection.search += text }
        }
    }

    private func editSearch(removing: Bool) {
        if mode == .applications {
            if !applicationWindows.search.isEmpty { applicationWindows.search.removeLast() }
        } else if !selection.search.isEmpty { selection.search.removeLast() }
    }
    private var gridColumns: Int { max(1, switcherLayout.columns) }

    func preferredScreen() -> NSScreen? {
        switch preferences.screenChoice {
        case "main": NSScreen.screens.first
        case "active": NSScreen.main
        default: NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        }
    }

    func begin(mode: SwitchMode = .windows, modifier: CGEventFlags = [], reverse: Bool = false, pointerScreen: NSScreen? = nil) {
        cancel()
        active = true; loading = true; self.mode = mode; heldModifier = modifier
        displayDelayElapsed = false
        searching = false; browsingApplicationWindows = false
        mouseAtOpen = NSEvent.mouseLocation; mouseSelectionEnabled = false
        cumulativeMouseDistance = 0
        pendingSteps = reverse ? -1 : 1; commitWhenLoaded = false; message = ""
        startingPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        sessionBegan = Date()
        let token = session
        let screen = preferredScreen()
        let query = listQuery(screen: screen)
        if mode == .windows, !modifier.isEmpty, preferences.quickSwitchOnMouseScreen {
            quickGesture = true
            let mouseScreen = pointerScreen ?? NSScreen.screens.first { NSMouseInRect(mouseAtOpen, $0.frame, false) } ?? NSScreen.main
            var local = listQuery(screen: mouseScreen)
            // All displays are read so a tap can fall back to another display; the pointer
            // display still comes first (QuickSwitchPolicy.candidates filters by screen).
            local.allSpaces = false; local.allScreens = true; local.includeMinimized = false; local.includeHidden = false
            quickQuery = local
            quickScreenBounds = local.screenBounds ?? .zero
            let top = NSScreen.screens.first?.frame.maxY ?? 0
            quickDisplayBounds = NSScreen.screens.map { CGRect(x: $0.frame.minX, y: top - $0.frame.maxY,
                                                             width: $0.frame.width, height: $0.frame.height) }
            let holdDelay = max(50, preferences.quickHoldDelay)
            displayWork = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(holdDelay))
                guard !Task.isCancelled, let self, self.session == token, self.active else { return }
                self.promoteQuickGesture()
            }
            return
        }
        let showDelay = preferences.showDelay
        displayWork = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(showDelay))
            guard !Task.isCancelled, let self, self.session == token, self.active else { return }
            self.displayDelayElapsed = true
            if !self.loading { self.showPanel(screen: screen); self.loadPreviews(token: token) }
        }
        discoverForList(query: query, screen: screen, token: token)
    }

    private func promoteQuickGesture() {
        guard quickGesture, active else { return }
        quickGesture = false; quickQuery = nil
        displayWork?.cancel(); displayWork = nil
        displayDelayElapsed = true
        let screen = preferredScreen()
        discoverForList(query: listQuery(screen: screen), screen: screen, token: session)
    }

    private func discoverForList(query: WindowQuery, screen: NSScreen?, token: UUID) {
        switchLog.debug("discover started after=\(Int(Date().timeIntervalSince(self.sessionBegan) * 1000), privacy: .public)ms mode=\(String(describing: self.mode), privacy: .public)")
        work = Task { [weak self] in
            guard let self else { return }
            var windows = await service.discover(query)
            switchLog.debug("discover returned after=\(Int(Date().timeIntervalSince(self.sessionBegan) * 1000), privacy: .public)ms count=\(windows.count, privacy: .public) current=\(self.session == token, privacy: .public)")
            clearClosedPreviews(await service.knownClosedWindowIDs())
            guard !Task.isCancelled, session == token, active else { return }
            if windows.isEmpty, mode == .currentApplication, let pid = query.currentPID,
               let app = NSRunningApplication(processIdentifier: pid) {
                windows = await recentDocumentItems(pid: pid, appName: app.localizedName ?? "应用", bundleID: app.bundleIdentifier ?? "")
                guard !Task.isCancelled, session == token, active else { return }
            }
            windows = listItems(windows)
            let evidence = await service.discoveryEvidenceSummary()
            switchLog.notice("list opened mode=\(String(describing: self.mode), privacy: .public) after=\(Int(Date().timeIntervalSince(self.sessionBegan) * 1000), privacy: .public)ms items=[\(describe(windows), privacy: .public)] \(evidence, privacy: .public)")
            dropPreviewsBelowSettings(windows)
            applyPreloadedThumbnails(to: windows)
            spaceNumbers = SpaceService.badges(windowIDs: windows.filter { !$0.isOnScreen }.compactMap(\.windowID))
            selection.start(windows, advance: false)
            selection.move(pendingSteps)
            loading = false
            if mode == .applications { loadApplicationWindows(token: token) }
            if windows.isEmpty { message = AXIsProcessTrusted() ? "没有符合条件的窗口" : "请先在设置中授予辅助功能权限" }
            if commitWhenLoaded { commit(); return }
            if displayDelayElapsed { showPanel(screen: screen); loadPreviews(token: token) }
            scheduleFullPreview()
            if mode != .applications { observeInventory(query: query, token: token, applicationWindowsOnly: false) }
        }
    }

    private func observeInventory(query: WindowQuery, token: UUID, applicationWindowsOnly: Bool) {
        inventoryWork?.cancel()
        inventoryWork = Task { [weak self] in
            guard let self else { return }
            var revision = (await service.discoveryStatus()).revision
            var incomplete = !(await service.discoveryStatus()).metadataComplete
            var visible = service.visibleWindowSignature()
            var ticks = 0
            while !Task.isCancelled, session == token, active {
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                guard !Task.isCancelled, session == token, active else { return }
                ticks += 1
                let status = await service.discoveryStatus()
                // A window appearing or disappearing on screen refreshes the list right away.
                let nowVisible = service.visibleWindowSignature()
                let visibleChanged = nowVisible != visible
                visible = nowVisible
                guard visibleChanged || status.revision != revision || (incomplete && ticks % 5 == 0) else { continue }
                let latest = applicationWindowsOnly ? gridCapacity(await service.discover(query)) : listItems(await service.discover(query))
                clearClosedPreviews(await service.knownClosedWindowIDs())
                guard !Task.isCancelled, session == token, active else { return }
                revision = (await service.discoveryStatus()).revision
                incomplete = !(await service.discoveryStatus()).metadataComplete
                let old = applicationWindowsOnly ? applicationWindows : selection
                // The panel is open: never move what is already shown.
                let windows = StableListOrder.merge(shown: old.items, latest: latest)
                guard old.items != windows else { continue }
                let oldIDs = Set(old.items.map(\.id))
                let added = windows.filter { !oldIDs.contains($0.id) }
                if !added.isEmpty {
                    switchLog.notice("list grew after=\(Int(Date().timeIntervalSince(self.sessionBegan) * 1000), privacy: .public)ms added=[\(describe(added), privacy: .public)] now=[\(describe(windows), privacy: .public)]")
                }
                if applicationWindowsOnly {
                    applicationWindows.start(windows, advance: false)
                    applicationWindows.search = old.search
                    if let id = old.selected?.id { applicationWindows.select(id) }
                } else {
                    selection.start(windows, advance: false)
                    selection.search = old.search
                    if let id = old.selected?.id { selection.select(id) }
                }
                spaceNumbers = SpaceService.badges(windowIDs: windows.filter { !$0.isOnScreen }.compactMap(\.windowID))
                updatePanel()
                if old.items.map(\.id) != windows.map(\.id) { loadPreviews(token: token) }
            }
        }
    }

    private func loadPreviews(token: UUID) {
        guard preferences.showPreviews else { return }
        previewWork?.cancel()
        let windows = displayedWindows
        let liveIDs = Set(windows.compactMap(\.windowID))
        if thumbnails.count > 100 {
            thumbnails = thumbnails.filter { liveIDs.contains($0.key) }
            previewStamps = previewStamps.filter { liveIDs.contains($0.key) }
            previewDates = previewDates.filter { liveIDs.contains($0.key) }
        }
        let request = thumbnailRequest
        // One capture at a time, at most 60 cached previews; no unbounded task fan-out.
        previewWork = Task { [weak self] in
            guard let self else { return }
            // Let the cached panel reach the compositor before any missing snapshot work.
            do { try await Task.sleep(for: .milliseconds(32)) } catch { return }
            let ordered = [displayedSelection.selected].compactMap { $0 } + windows
            var seen: Set<UInt32> = []
            for item in ordered {
                guard !Task.isCancelled, session == token, active else { return }
                guard let id = item.windowID, seen.insert(id).inserted else { continue }
                guard seen.count <= 60 else { break }
                guard needsThumbnail(item, request: request) else { continue }
                if let image = await service.thumbnail(windowID: id, maxPixelSize: request.pixelSize, interpolationQuality: request.quality) {
                    guard !Task.isCancelled, session == token, active else { return }
                    thumbnails[id] = NSImage(cgImage: image, size: .zero)
                    previewStamps[id] = ThumbnailStamp(windowSize: item.frame.size, request: request); previewDates[id] = Date()
                    do { try await Task.sleep(for: .milliseconds(32)) } catch { return }
                }
            }
        }
    }

    func advance(_ amount: Int) {
        if loading { pendingSteps += amount }
        else {
            selection.move(amount)
            if mode == .applications { browsingApplicationWindows = false; loadApplicationWindows(token: session) }
            scheduleFullPreview()
        }
    }
    func moveWindow(_ amount: Int) {
        if mode == .applications {
            if nativeSession && !browsingApplicationWindows {
                if let first = applicationWindows.filtered.first { applicationWindows.select(first.id) }
            } else { applicationWindows.move(amount) }
            browsingApplicationWindows = true
        }
        else { selection.move(amount) }
        scheduleFullPreview()
    }
    func moveRow(_ direction: Int) {
        if mode == .applications {
            if nativeSession && !browsingApplicationWindows {
                if let first = applicationWindows.filtered.first { applicationWindows.select(first.id) }
            } else { applicationWindows.moveRow(direction, columns: gridColumns) }
            browsingApplicationWindows = true
        }
        else { selection.moveRow(direction, columns: gridColumns) }
        scheduleFullPreview()
    }

    func loadThumbnail(_ item: WindowItem) async {
        let request = thumbnailRequest
        guard active, preferences.showPreviews, let id = item.windowID, needsThumbnail(item, request: request) else { return }
        let token = session
        guard let image = await service.thumbnail(windowID: id, maxPixelSize: request.pixelSize, interpolationQuality: request.quality),
              !Task.isCancelled, active, session == token else { return }
        if thumbnails.count >= 60, let victim = thumbnails.keys.first(where: { $0 != displayedSelection.selected?.windowID }) {
            thumbnails[victim] = nil
            previewStamps[victim] = nil; previewDates[victim] = nil
        }
        thumbnails[id] = NSImage(cgImage: image, size: .zero)
        previewStamps[id] = ThumbnailStamp(windowSize: item.frame.size, request: request); previewDates[id] = Date()
    }
    func hover(_ id: String) {
        let point = NSEvent.mouseLocation
        cumulativeMouseDistance += hypot(point.x - mouseAtOpen.x, point.y - mouseAtOpen.y)
        mouseAtOpen = point
        if cumulativeMouseDistance > 20 { mouseSelectionEnabled = true }
        guard mouseSelectionEnabled else { return }
        selectWindow(id)
    }
    func selectWindow(_ id: String) {
        let changed = displayedSelection.selected?.id != id || (mode == .applications && !browsingApplicationWindows)
        guard changed else { return }
        if mode == .applications { applicationWindows.select(id); browsingApplicationWindows = true }
        else { selection.select(id) }
        if changed { scheduleFullPreview() }
    }
    func choose(_ id: String) { selectWindow(id); commit() }
    func selectApplication(_ id: String) {
        browsingApplicationWindows = false
        selection.select(id); loadApplicationWindows(token: session)
    }

    func resetInput() { cancel(); suppressedKeys.removeAll() }

    func waitForQuickSwitch() async { await quickFocusWork?.value }
    var panelIsVisible: Bool { panel?.isVisible == true }
    var panelAlpha: Double { Double(panel?.alphaValue ?? 0) }
    var preloadedThumbnailCount: Int { preloadedThumbnails.count }
    var preloadedWindowCount: Int { preloadedWindows.count }

    func nativeApplicationSelected(pid: Int32?, visible: Bool, listFrame: CGRect? = nil, selectedAppFrame: CGRect? = nil) {
        guard preferences.enabled, preferences.applicationSwitcher, preferences.nativeAppEnhancement else { return }
        if !visible {
            if nativeSession {
                if browsingApplicationWindows { commit() } else { cancel() }
            }
            return
        }
        guard let pid, let app = NSRunningApplication(processIdentifier: pid),
              !preferences.excludedApplications.split(whereSeparator: { $0.isWhitespace || $0 == "," }).contains(Substring(app.bundleIdentifier ?? "")) else {
            if nativeSession { cancel() }
            return
        }
        let first = !nativeSession
        if first { cancel(); active = true; nativeSession = true; mode = .applications; heldModifier = .maskCommand }
        if first { mouseAtOpen = NSEvent.mouseLocation; cumulativeMouseDistance = 0; mouseSelectionEnabled = false }
        nativeListFrame = listFrame; nativeSelectedAppFrame = selectedAppFrame
        browsingApplicationWindows = false
        selection.start([WindowItem(id: "app:\(pid)", windowID: nil, pid: pid, appName: app.localizedName ?? "应用",
                                   bundleID: app.bundleIdentifier ?? "", title: app.localizedName ?? "应用", frame: .zero)], advance: false)
        loadApplicationWindows(token: session, delay: first ? preferences.applicationInitialDelay : preferences.applicationSubsequentDelay)
        autoActivateWork?.cancel()
        if preferences.applicationAutoActivate {
            let token = session
            autoActivateWork = Task {
                try? await Task.sleep(for: .milliseconds(preferences.applicationAutoActivateDelay))
                guard !Task.isCancelled, session == token, nativeSession, !browsingApplicationWindows,
                      selection.selected?.pid == pid else { return }
                _ = app.activate(options: [.activateAllWindows])
            }
        }
    }

    private func loadApplicationWindows(token: UUID, delay: Double? = nil) {
        applicationWork?.cancel()
        guard let app = selection.selected else { return }
        applicationWindows.start([], advance: false)
        var query = preferences.query(mode: .currentApplication, currentPID: app.pid, screen: preferredScreen())
        if nativeSession { query.allScreens = true }
        applicationWork = Task {
            try? await Task.sleep(for: .milliseconds(delay ?? preferences.applicationSubsequentDelay))
            guard !Task.isCancelled, session == token, selection.selected?.pid == app.pid else { return }
            var windows = await service.discover(query)
            guard !Task.isCancelled, session == token, selection.selected?.pid == app.pid else { return }
            if windows.isEmpty {
                windows = await recentDocumentItems(pid: app.pid, appName: app.appName, bundleID: app.bundleID)
                guard !Task.isCancelled, session == token, selection.selected?.pid == app.pid else { return }
            }
            windows = gridCapacity(windows)
            spaceNumbers = SpaceService.badges(windowIDs: windows.filter { !$0.isOnScreen }.compactMap(\.windowID))
            applicationWindows.start(windows, advance: false)
            if nativeSession { showPanel(screen: preferredScreen()) }
            loadPreviews(token: token)
            observeInventory(query: query, token: token, applicationWindowsOnly: true)
        }
    }

    private func recentDocumentItems(pid: Int32, appName: String, bundleID: String) async -> [WindowItem] {
        let result = await LibraryIndex.shared.recentDocuments(bundleID: bundleID)
        return result.items.map {
            WindowItem(id: "doc:\($0.url.path)", windowID: nil, pid: pid, appName: appName,
                       bundleID: bundleID, title: $0.name, frame: .zero, documentURL: $0.url)
        }.filter { !WindowRule.excludes($0, rules: preferences.windowRules) }
    }

    func commit() {
        guard active else { return }
        if quickGesture, let query = quickQuery {
            let screen = quickScreenBounds, screens = quickDisplayBounds
            let preceding = quickFocusWork
            cancel()
            // Serialize taps so the next query observes the preceding activation.
            // Starting a new gesture must not cancel an activation already submitted.
            quickFocusWork = Task { [weak self] in
                await preceding?.value
                guard let self else { return }
                let began = Date()
                let focused = await service.frontmostWindowID()
                let focusedPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
                let windows = await service.discover(query, cachedOnly: true)
                clearClosedPreviews(await service.knownClosedWindowIDs())
                let candidatesOnScreen = QuickSwitchPolicy.candidates(windows, screen: screen, screens: screens)
                let local = preferences.oneWindowPerApp ? WindowGrouping.onePerApplication(candidatesOnScreen) : candidatesOnScreen
                lastQuickEvidence = ["candidateIDs": local.compactMap(\.windowID).map(String.init).joined(separator: ",")]
                lastQuickEvidence["observedFocusedID"] = focused.map(String.init) ?? "none"
                var candidates = QuickSwitchPolicy.orderedTargets(local, focusedWindowID: focused, focusedPID: focusedPID)
                var scope = "pointer-display"
                if candidates.isEmpty {
                    let visible = preferences.oneWindowPerApp ? WindowGrouping.onePerApplication(windows) : windows
                    candidates = QuickSwitchPolicy.fallbackTargets(visible, focusedWindowID: focused, focusedPID: focusedPID)
                    scope = "any-display"
                }
                guard let firstTarget = candidates.first else {
                    switchLog.notice("quick tap: nothing to switch to focused=\(focused.map(String.init) ?? "none", privacy: .public) pointerDisplay=[\(describe(local), privacy: .public)]")
                    return
                }
                var target = firstTarget, accepted = false
                for candidate in candidates.prefix(8) {
                    target = candidate
                    accepted = await service.perform(.focus, on: target)
                    if accepted { break }
                    guard await service.isWindowMissing(target) else { break }
                    if let id = target.windowID {
                        thumbnails[id] = nil; previewStamps[id] = nil; previewDates[id] = nil; preloadedThumbnails[id] = nil
                        preloadedWindows.removeAll { $0.windowID == id }
                    }
                    if Date().timeIntervalSince(began) > 0.15 { break }
                }
                lastQuickEvidence["targetID"] = target.windowID.map(String.init)
                lastQuickEvidence["focusAccepted"] = "\(accepted)"
                switchLog.notice("quick tap: \(scope, privacy: .public) focused=\(focused.map(String.init) ?? "none", privacy: .public) target=\(describe([target]), privacy: .public) accepted=\(accepted, privacy: .public) ms=\(Int(Date().timeIntervalSince(began) * 1000), privacy: .public)")
                lastQuickEvidence["queryAndActivationMS"] = "\(Date().timeIntervalSince(began) * 1000)"
                if !accepted { message = "当前无法切换到该窗口" }
            }
            return
        }
        if loading { commitWhenLoaded = true; return }
        let target = chosenWindow
        let wasNative = nativeSession
        let openDefault = preferences.openDefaultWindow && target?.id.hasPrefix("app:") == true && target?.windowID == nil
        cancel()
        guard let target else { return }
        let token = session
        actionWork = Task {
            if wasNative { try? await Task.sleep(for: .milliseconds(50)) }
            guard !Task.isCancelled, session == token else { return }
            if !(await service.perform(.focus, on: target)) {
                message = "窗口已关闭或当前无法切换"
            } else if openDefault, !Task.isCancelled, session == token {
                _ = await service.perform(.newWindow, on: target)
            }
        }
    }

    func cancel() {
        dismissalWork?.cancel()
        session = UUID(); work?.cancel(); previewWork?.cancel(); displayWork?.cancel()
        applicationWork?.cancel(); hoverWork?.cancel(); fullPreview?.orderOut(nil)
        actionWork?.cancel(); actionWork = nil
        autoActivateWork?.cancel(); autoActivateWork = nil
        inventoryWork?.cancel(); inventoryWork = nil
        work = nil; previewWork = nil; displayWork = nil
        active = false; loading = false; expanded = false
        quickGesture = false; quickQuery = nil
        if preferences.hideAnimation == "fade", panel?.isVisible == true {
            fadePanel(to: 0, milliseconds: preferences.fadeOutDuration, hiding: true)
        } else { panel?.orderOut(nil) }
        nativeSession = false
        nativeListFrame = nil; nativeSelectedAppFrame = nil
    }

    func perform(_ action: WindowAction) {
        guard let item = chosenWindow else { return }
        let token = session
        actionWork?.cancel()
        actionWork = Task {
            guard !Task.isCancelled, session == token, active else { return }
            let success = await service.perform(action, on: item)
            guard !Task.isCancelled, session == token, active else { return }
            if success {
                if action == .hideApplication || action == .quitApplication || action == .forceQuitApplication {
                    selection.removeApplication(pid: item.pid)
                    applicationWindows.removeApplication(pid: item.pid)
                    if selection.items.isEmpty { cancel() }
                } else if action == .close {
                    if mode == .applications { applicationWindows.remove(item.id) }
                    else { selection.remove(item.id) }
                }
                if action == .newWindow || action == .newTab || action == .openFile || action == .toggleFullscreen || action == .bringToCurrentSpace { cancel() }
                message = ""
            } else {
                message = "这个窗口当前不支持该操作，或正在等待确认"
                if action == .close || action == .quitApplication { cancel() }
            }
        }
    }

    private func scheduleFullPreview() {
        hoverWork?.cancel(); fullPreview?.orderOut(nil)
        if nativeSession && !browsingApplicationWindows { return }
        guard preferences.showPreviews, preferences.hoverPreview, let item = displayedSelection.selected, let id = item.windowID else { return }
        let token = session
        hoverWork = Task {
            try? await Task.sleep(for: .milliseconds(preferences.hoverDelay))
            guard !Task.isCancelled, session == token, active,
                  let image = await service.fullWindowPreview(windowID: id,
                    allowRetina: (preferredScreen()?.backingScaleFactor ?? 2) > 1.1,
                    interpolationQuality: preferences.previewQuality) else { return }
            guard !Task.isCancelled, session == token, active else { return }
            if fullPreview == nil {
                let preview = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                preview.isOpaque = false; preview.backgroundColor = .clear; preview.ignoresMouseEvents = true
                preview.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
                preview.alphaValue = 0.9
                preview.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
                fullPreview = preview
            }
            let top = NSScreen.screens.first?.frame.maxY ?? CGDisplayBounds(CGMainDisplayID()).height
            let rect = CGRect(x: item.frame.minX, y: top - item.frame.maxY, width: item.frame.width, height: item.frame.height)
            fullPreview?.contentView = NSHostingView(rootView: Image(nsImage: NSImage(cgImage: image, size: .zero)).resizable().scaledToFit())
            fullPreview?.setFrame(rect, display: true); fullPreview?.orderFrontRegardless()
        }
    }

    /// Warm SwiftUI/AppKit once during launch, with the panel kept hidden.
    /// This performs no window capture and runs before the first shortcut.
    func prepareInterface() {
        if panel == nil {
            let panel = SwitchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = preferences.theme == "classic"
            panel.becomesKeyOnlyIfNeeded = true; panel.acceptsMouseMovedEvents = true
            panel.level = .popUpMenu; panel.hidesOnDeactivate = false
            panel.collectionBehavior = NSWindow.CollectionBehavior(rawValue: 0x152)
            panel.contentView = NSHostingView(rootView: SwitcherView(controller: self))
            self.panel = panel
            panel.setFrame(switcherLayout.panelFrame, display: false)
            panel.contentView?.layoutSubtreeIfNeeded()
        }
    }

    func warmInterface() async {
        guard !active else { return }
        let windows = listItems(await service.discover(listQuery(screen: preferredScreen()), cachedOnly: true))
        guard !active else { return }
        selection.start(windows, advance: false)
        prepareInterface()
        updatePanel()
        panel?.contentView?.layoutSubtreeIfNeeded()
    }

    private func showPanel(screen: NSScreen?) {
        if panel?.isVisible != true {
            switchLog.notice("panel shown after=\(Int(Date().timeIntervalSince(self.sessionBegan) * 1000), privacy: .public)ms loading=\(self.loading, privacy: .public) items=[\(describe(self.displayedWindows), privacy: .public)]")
        }
        dismissalWork?.cancel()
        prepareInterface()
        let wasVisible = panel?.isVisible == true
        if !wasVisible { mouseAtOpen = NSEvent.mouseLocation; cumulativeMouseDistance = 0; mouseSelectionEnabled = false }
        updatePanel(screen: screen)
        if !wasVisible { panel?.alphaValue = 0 }
        panel?.orderFrontRegardless()
        if panel?.alphaValue != 1 { fadePanel(to: 1, milliseconds: preferences.fadeInDuration, hiding: false) }
    }

    private func fadePanel(to target: Double, milliseconds: Double, hiding: Bool) {
        dismissalWork?.cancel()
        guard let panel else { return }
        let duration = min(max(milliseconds.isFinite ? milliseconds : (hiding ? 200 : 100), 0), 5000) / 1000
        let initial = panel.alphaValue
        if duration == 0 {
            panel.alphaValue = target
            if hiding { panel.orderOut(nil); panel.alphaValue = 1 }
            return
        }
        let token = session, start = CACurrentMediaTime()
        dismissalWork = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, session == token, active != hiding else { return }
                let progress = min(1, (CACurrentMediaTime() - start) / duration)
                panel.alphaValue = initial + (target - initial) * progress
                if progress >= 1 {
                    if hiding { panel.orderOut(nil); panel.alphaValue = 1 }
                    return
                }
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            }
        }
    }

    func refreshBackgroundPreloading(permitted: Bool) {
        var query = preferences.query(mode: .windows, currentPID: nil, screen: preferredScreen())
        query.allowedPIDs = windowScope
        let interval = min(max(preferences.backgroundPreloadInterval.isFinite ? preferences.backgroundPreloadInterval : 30, 1), 3600)
        // Prefetch at the size the switcher will display, so a prefetched preview is final
        // and the open panel does not visibly swap a blurry placeholder for a sharp capture.
        let request = ThumbnailRequest(contentSize: thumbnailContentSize, backingScale: preferredScreen()?.backingScaleFactor ?? 1,
                                       quality: preferences.previewQuality)
        let configuration = BackgroundPreloadConfiguration(enabled: permitted && preferences.backgroundPreloadEnabled,
            thumbnails: preferences.backgroundPreloadThumbnails && preferences.showPreviews, interval: interval,
            query: query, request: request)
        guard configuration != preloadConfiguration else { return }
        let restart = preloadConfiguration.map {
            $0.enabled != configuration.enabled || $0.thumbnails != configuration.thumbnails || $0.interval != configuration.interval
        } ?? true
        // Moving the pointer to another screen updates the next cycle's scope;
        // it must not restart a 30-second timer every time refreshHooks runs.
        if !restart { preloadConfiguration = configuration; return }
        stopBackgroundPreloading()
        preloadConfiguration = configuration
        guard configuration.enabled else { preferences.preloadStatus = ""; return }
        let token = preloadToken, service = service, resources = backgroundResources
        preloadWork = Task.detached(priority: .background) { [weak self] in
            var cursor = 0
            var costMultiplier = 1.0
            while !Task.isCancelled {
                guard await self?.preloadAllowed(token) == true else {
                    if Task.isCancelled { return }
                    do { try await Task.sleep(for: .seconds(2), tolerance: .milliseconds(250)) } catch { return }
                    continue
                }
                guard let configuration = await self?.currentPreloadConfiguration(token) else { return }
                let policy = BackgroundWorkPolicy(resources())
                guard policy.allowMetadata else {
                    await self?.setPreloadWaitingStatus(token)
                    do { try await Task.sleep(for: .seconds(2), tolerance: .milliseconds(250)) } catch { return }
                    continue
                }
                let cycleStart = CACurrentMediaTime()
                let windows = await service.discover(configuration.query, cachedOnly: true)
                guard !Task.isCancelled else { return }
                await self?.acceptPreloadInventory(windows, token: token)
                let eligible = Array(windows.filter { $0.windowID != nil }.prefix(32))
                // One scaled screenshot per cycle: no fan-out or catch-up burst.
                // Slow captures and resource pressure lengthen the next interval.
                if configuration.thumbnails, policy.allowThumbnails, !eligible.isEmpty {
                    for _ in 0..<1 {
                        guard !Task.isCancelled,
                              await self?.preloadAllowed(token) == true else { break }
                        let item = eligible[cursor % eligible.count]; cursor += 1
                        guard let id = item.windowID else { continue }
                        let captureStart = CACurrentMediaTime()
                        if let image = await service.thumbnail(windowID: id, maxPixelSize: configuration.request.pixelSize,
                            interpolationQuality: configuration.request.quality, refresh: true, mayCapture: { BackgroundWorkPolicy(resources()).allowThumbnails }) {
                            await self?.acceptPreloadedImage(image, item: item, request: configuration.request, token: token)
                        }
                        costMultiplier = CACurrentMediaTime() - captureStart > 0.25 ? min(4, costMultiplier * 2) : max(1, costMultiplier / 2)
                    }
                }
                let remaining = max(0.1, configuration.interval * max(policy.intervalMultiplier, costMultiplier) - (CACurrentMediaTime() - cycleStart))
                do { try await Task.sleep(for: .seconds(remaining), tolerance: .seconds(min(1, remaining * 0.1))) } catch { return }
            }
        }
    }

    func stopBackgroundPreloading() {
        preloadToken = UUID(); preloadWork?.cancel(); preloadWork = nil
        preloadConfiguration = nil
    }
    private func preloadAllowed(_ token: UUID) -> Bool { token == preloadToken && !active && panel?.isVisible != true }
    private func currentPreloadConfiguration(_ token: UUID) -> BackgroundPreloadConfiguration? {
        token == preloadToken ? preloadConfiguration : nil
    }
    private func setPreloadWaitingStatus(_ token: UUID) {
        guard token == preloadToken else { return }
        let status = "Waiting for idle time and low system load"
        if preferences.preloadStatus != status { preferences.preloadStatus = status }
    }
    private func acceptPreloadInventory(_ windows: [WindowItem], token: UUID) {
        guard token == preloadToken else { return }
        preloadedWindows = windows
        let ids = Set(windows.compactMap(\.windowID))
        preloadedThumbnails = preloadedThumbnails.filter { ids.contains($0.key) }
        preferences.preloadStatus = "\(windows.count) windows · \(preloadedThumbnails.count) previews in memory"
    }
    private func acceptPreloadedImage(_ image: CGImage, item: WindowItem, request: ThumbnailRequest, token: UUID) {
        guard token == preloadToken, let id = item.windowID else { return }
        preloadedThumbnails[id] = PreloadedThumbnail(image: NSImage(cgImage: image, size: .zero), stamp: ThumbnailStamp(windowSize: item.frame.size, request: request), updated: Date())
        while preloadedThumbnails.count > 32, let oldest = preloadedThumbnails.min(by: { $0.value.updated < $1.value.updated })?.key {
            preloadedThumbnails[oldest] = nil
        }
    }
    /// Runs before the panel is visible. A preview captured under an older quality, size or
    /// display-scale setting is dropped so it is captured fresh (blank to image) rather than
    /// staying low-resolution forever or being swapped while the panel is shown.
    private func dropPreviewsBelowSettings(_ windows: [WindowItem]) {
        guard panel?.isVisible != true else { return }
        let request = thumbnailRequest
        for item in windows {
            guard let id = item.windowID, thumbnails[id] != nil else { continue }
            if previewStamps[id]?.request.satisfies(request) != true {
                thumbnails[id] = nil; previewStamps[id] = nil; previewDates[id] = nil
            }
        }
    }
    private func applyPreloadedThumbnails(to windows: [WindowItem]) {
        guard preferences.backgroundPreloadEnabled, preferences.backgroundPreloadThumbnails else { return }
        for item in windows {
            guard let id = item.windowID, let cached = preloadedThumbnails[id],
                  cached.stamp.request.satisfies(thumbnailRequest) else { continue }
            // Runs before the panel is visible: a newer background capture replaces the cached one.
            if let current = previewStamps[id], current.request.quality > cached.stamp.request.quality { continue }
            if let date = previewDates[id], date >= cached.updated { continue }
            if thumbnails[id] !== cached.image { thumbnails[id] = cached.image }
            previewStamps[id] = cached.stamp; previewDates[id] = cached.updated
        }
    }

    private func clearClosedPreviews(_ ids: Set<UInt32>) {
        for id in ids { thumbnails[id] = nil; previewStamps[id] = nil; previewDates[id] = nil; preloadedThumbnails[id] = nil }
        preloadedWindows.removeAll { $0.windowID.map(ids.contains) == true }
    }

    func updatePanel(screen: NSScreen? = nil) {
        guard let panel else { return }
        let selectedScreen = screen ?? preferredScreen()
        let frame = selectedScreen?.frame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let layout = SwitcherLayout(count: displayedWindows.count, preferredWidth: preferences.thumbnailSize,
                                            screenFrame: frame, visibleFrame: selectedScreen?.visibleFrame ?? frame,
                                            nativeListFrame: nativeSession ? nativeListFrame : nil,
                                            selectedApplicationFrame: nativeSession ? nativeSelectedAppFrame : nil)
        if panel.frame != layout.panelFrame { panel.setFrame(layout.panelFrame, display: true) }
    }

    func showDemo() {
        cancel(); active = true
        let names = [("Safari", "项目文档 · 工作空间", "com.apple.Safari"),
                     ("Xcode", "WindowSwitch — 原生窗口切换", "com.apple.dt.Xcode"),
                     ("Terminal", "构建与验证", "com.apple.Terminal"),
                     ("Finder", "PersonalProjects", "com.apple.finder")]
        selection.start(names.enumerated().map { index, data in
            WindowItem(id: "demo-\(index)", windowID: nil, pid: 0, appName: data.0,
                       bundleID: data.2, title: data.1, frame: .zero)
        })
        showPanel(screen: preferredScreen())
    }

    /// Pure controller checks: constructs local CGEvent values but never posts
    /// input, installs hooks, discovers windows, or acts on another application.
    func validateInputState() -> [String: Bool] {
        let windows = (0..<3).map {
            WindowItem(id: "input-\($0)", windowID: nil, pid: 0, appName: "Fixture", bundleID: "fixture",
                       title: "Window \($0)", frame: .zero)
        }
        func seed() {
            cancel(); nativeSession = true; mode = .applications; active = true
            browsingApplicationWindows = false; heldModifier = .maskCommand
            applicationWindows.start(windows, advance: false)
        }
        func key(_ code: CGKeyCode, shift: Bool = false) -> Bool {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true) else { return false }
            event.flags = shift ? [.maskCommand, .maskShift] : .maskCommand
            return handle(type: .keyDown, event: event)
        }
        var result: [String: Bool] = [:]
        seed(); _ = key(50); result["firstGraveSelectsFirst"] = applicationWindows.selected?.id == "input-0" && browsingApplicationWindows
        seed(); _ = key(50, shift: true); result["firstReverseGraveSelectsFirst"] = applicationWindows.selected?.id == "input-0"
        seed(); _ = key(125); result["firstDownSelectsFirst"] = applicationWindows.selected?.id == "input-0" && browsingApplicationWindows
        _ = key(125); result["secondDownAdvances"] = applicationWindows.selected?.id == "input-1"
        _ = key(126); result["upClearsWindowHighlight"] = !browsingApplicationWindows
        seed(); result["leftPassesToNativeSwitcher"] = !key(123) && !browsingApplicationWindows
        seed(); result["rightPassesToNativeSwitcher"] = !key(124) && !browsingApplicationWindows
        seed(); result["tabPassesToNativeSwitcher"] = !key(48)
        cancel(); suppressedKeys.removeAll()
        return result
    }

    func renderDemo(to path: String) throws {
        guard let view = panel?.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let data = bitmap.representation(using: .png, properties: [:]) { try data.write(to: URL(fileURLWithPath: path)) }
    }

    func showFixturePreview(_ items: [WindowItem], images: [UInt32: CGImage]) {
        cancel(); active = true; loading = false; mode = .currentApplication
        selection.start(gridCapacity(items))
        thumbnails = images.mapValues { NSImage(cgImage: $0, size: .zero) }
        showPanel(screen: preferredScreen())
    }
}

private final class SwitchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
