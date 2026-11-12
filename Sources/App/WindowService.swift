import AppKit
import ApplicationServices
import CoreGraphics
@preconcurrency import ScreenCaptureKit
import WindowSwitchCore

private nonisolated struct ApplicationSnapshot: Sendable {
    let pid: Int32
    let name: String
    let bundleID: String
    let hidden: Bool
    let launched: Date
}

private nonisolated struct CompositorWindow: Sendable {
    let id: UInt32
    let pid: Int32
    let title: String
    let frame: CGRect
    let onScreen: Bool
    let order: Int
    let layer: Int
}

private nonisolated struct ThumbnailKey: Hashable, Sendable {
    let windowID: UInt32
    let width: Int
    let height: Int
    let quality: Int
    let fullRetina: Bool?
}

private nonisolated struct WindowCaptureResult: Sendable {
    let image: CGImage?
    let evidence: [String: String]
}

/// Blocking WindowServer capture has a separate executor from list/focus work.
private actor WindowCaptureWorker {
    func capture(_ key: ThumbnailKey) -> WindowCaptureResult {
        var evidence = WSCaptureEvidence()
        let began = Date()
        let box = key.fullRetina == nil ? CGSize(width: key.width, height: key.height) : .zero
        let image = WSCreateWindowPreview(key.windowID, box, Int32(key.quality), key.fullRetina ?? false, &evidence)
        return WindowCaptureResult(image: image, evidence: [
            "backend": image == nil ? "window-capture-unavailable" : "WindowServer",
            "primaryImageReturned": "\(evidence.primaryImageReturned.boolValue)",
            "width": "\(evidence.outputWidth)", "height": "\(evidence.outputHeight)",
            "composedChildren": "\(evidence.composedChildren)", "quality": "\(key.quality)",
            "AXChildFallback": "\(evidence.usedAXChildFallback.boolValue)",
            "taskPriority": "\(Task.currentPriority.rawValue)",
            "threadQoS": "\(Thread.current.qualityOfService.rawValue)",
            "captureMS": "\(Date().timeIntervalSince(began) * 1000)"])
    }
}

/// AX handles remain on this actor; callers receive value snapshots only.
/// before a window action can run, so a stale selection cannot target a sibling.
actor WindowService {
    nonisolated static let syntheticEventMarker: Int64 = 0x5753_4B45_59
    private var elements: [String: AXUIElement] = [:]
    private var elementPIDs: [String: Int32] = [:]
    private var shareable: [UInt32: SCWindow] = [:]
    private var shareableUpdated = Date.distantPast
    private var contentRefresh: Task<Void, Never>?
    private var contentRefreshToken = UUID()
    private var thumbnails: [ThumbnailKey: (image: CGImage, updated: Date)] = [:]
    private var pendingThumbnails: [ThumbnailKey: Task<CGImage?, Never>] = [:]
    private var activeCaptures = 0
    private var singleWindowFocus = true
    private var restoreFrames: [String: (frame: CGRect, updated: Date)] = [:]
    private let inventoryWorker = WindowInventoryWorker()
    private let windowCaptureWorker = WindowCaptureWorker()
    private var captureEvidence: [UInt32: [String: String]] = [:]
    private var inventory: [Int32: [String: InventoryMetadata]] = [:]
    private var inventoryUpdated: [Int32: Date] = [:]
    private var inventoryClassifiedCGIDs: [Int32: Set<UInt32>] = [:]
    private var inventoryPublishRevision: UInt64 = 0
    private var workspaceCache: [ApplicationSnapshot] = []
    private var workspaceCacheUpdated = Date.distantPast
    private var workspaceNeedsRefresh = true
    private var workspaceRevision: UInt64 = 0
    private var workspaceRefresh: Task<[ApplicationSnapshot], Never>?
    private var workspaceRefreshToken = UUID()
    private var missingWorkspacePIDProbe: [Int32: Date] = [:]
    private var inventoryAttempted: [Int32: Date] = [:]
    private var inventoryRevision: [Int32: UInt64] = [:]
    private var dirtyPIDs: Set<Int32> = []
    private var refreshingPIDs: Set<Int32> = []
    private var unreachablePIDs: Set<Int32> = []
    private var maintenance: Task<Void, Never>?
    private var maintenanceTicker: Task<Void, Never>?
    private var delayedInventoryWake: Task<Void, Never>?
    private var inventoryWake: AsyncStream<Void>.Continuation?
    private var maintenanceStarting = false
    private var maintenanceGeneration = UUID()
    private var workspaceSignals: WindowWorkspaceSignals?
    private var workloadScans = 0
    private var workloadAXBatches = 0
    private var workloadAXFallbacks = 0
    private var workloadSCKRefreshes = 0
    private var lastDiscoveryEvidence: [String: Any] = [:]
    private var lastFocusEvidence: [String: String] = [:]
    private var lastLookupEvidence: [String: String] = [:]
    private var captureCount = 0
    private var closedWindowIDs: [UInt32: Int32] = [:]
    private var recency = WindowRecency()

    func focusDiagnostics() -> [String: String] { lastFocusEvidence }
    func captureDiagnostics(windowID: UInt32) -> [String: String] { captureEvidence[windowID] ?? [:] }
    func snapshotCaptureCount() -> Int { captureCount }
    func isWindowMissing(_ item: WindowItem) -> Bool {
        item.windowID.map { closedWindowIDs[$0] == item.pid } ?? false
    }
    func knownClosedWindowIDs() -> Set<UInt32> { Set(closedWindowIDs.keys) }
    func refreshApplicationInventory(pid: Int32) async {
        guard let app = await cachedWorkspaceSnapshot(currentPID: pid).first(where: { $0.pid == pid }) else { return }
        for _ in 0..<2 {
            if await refreshInventory(app) { break }
        }
    }

    private func forgetWindow(pid: Int32, id: UInt32) {
        recency.remove(pid: pid, windowID: id)
        closedWindowIDs[id] = pid
        inventory[pid] = inventory[pid]?.filter { $0.value.windowID != id }
        let stale = elements.compactMap { key, element in
            elementPIDs[key] == pid && SingleWindowActivation.windowID(for: element) == id ? key : nil
        }
        for key in stale { elements[key] = nil; elementPIDs[key] = nil }
        thumbnails = thumbnails.filter { $0.key.windowID != id }
        for (key, task) in pendingThumbnails where key.windowID == id { task.cancel() }
        inventoryPublishRevision &+= 1
    }

    func frontmostWindowID() async -> UInt32? {
        guard let pid = await MainActor.run(body: { NSWorkspace.shared.frontmostApplication?.processIdentifier }) else { return nil }
        return readAndRecordFocusedWindow(pid: pid)
    }

    private func recordForegroundWindow(pid: Int32) async {
        guard await MainActor.run(body: { NSWorkspace.shared.frontmostApplication?.processIdentifier }) == pid else { return }
        _ = readAndRecordFocusedWindow(pid: pid)
    }

    private func readAndRecordFocusedWindow(pid: Int32) -> UInt32? {
        guard pid != ProcessInfo.processInfo.processIdentifier else { return nil }
        let root = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(root, 0.04)
        guard let element = Self.element(kAXFocusedWindowAttribute, of: root),
              let id = SingleWindowActivation.windowID(for: element), closedWindowIDs[id] != pid else { return nil }
        recordFocus(pid: pid, windowID: id)
        return id
    }

    private func recordFocus(pid: Int32, windowID: UInt32) {
        if recency.record(pid: pid, windowID: windowID) { inventoryPublishRevision &+= 1 }
    }

    func discoveryEvidenceSummary() -> String {
        let e = lastDiscoveryEvidence
        func value(_ key: String) -> String { e[key].map { String(describing: $0) } ?? "?" }
        return "strategy=\(value("strategy")) metadataComplete=\(value("metadataComplete")) provisional=\(value("provisionalRows")) "
            + "pending=\(value("pendingClassification")) foregroundAXScans=\(value("foregroundAXScans")) dropped=\(value("droppedOnScreen"))"
    }
    func discoveryStatus() -> (metadataComplete: Bool, provisionalRows: Int, revision: UInt64) {
        (lastDiscoveryEvidence["metadataComplete"] as? Bool ?? false,
         lastDiscoveryEvidence["provisionalRows"] as? Int ?? 0, inventoryPublishRevision)
    }

    func setSingleWindowFocus(_ enabled: Bool) { singleWindowFocus = enabled }

    func startBackgroundMaintenance() async {
        guard maintenance == nil, !maintenanceStarting, AXIsProcessTrusted() else { return }
        maintenanceStarting = true
        defer { maintenanceStarting = false }
        let token = UUID(); maintenanceGeneration = token
        let signals = await WindowWorkspaceSignals { [weak self] pid, activated in
            Task {
                await self?.workspaceDidChange(pid: pid)
                if activated, let pid { await self?.recordForegroundWindow(pid: pid) }
            }
        }
        guard maintenanceGeneration == token else { await signals.stop(); return }
        workspaceSignals = signals
        let (events, wake) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        inventoryWake = wake
        maintenance = Task.detached(priority: .background) { [weak self] in
            for await _ in events {
                guard !Task.isCancelled else { return }
                for _ in 0..<64 {
                    guard !Task.isCancelled, await self?.maintainOneApplication() == true else { break }
                    do { try await Task.sleep(for: .milliseconds(25)) } catch { return }
                }
            }
        }
        maintenanceTicker = Task.detached(priority: .background) { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15), tolerance: .seconds(2)) } catch { return }
                await self?.wakeInventory()
            }
        }
        wake.yield(())
        _ = await frontmostWindowID()
    }

    func stopBackgroundMaintenance() async {
        maintenanceGeneration = UUID()
        maintenance?.cancel(); maintenance = nil
        maintenanceTicker?.cancel(); maintenanceTicker = nil
        delayedInventoryWake?.cancel(); delayedInventoryWake = nil
        inventoryWake?.finish(); inventoryWake = nil
        if let workspaceSignals { await workspaceSignals.stop() }
        workspaceSignals = nil
        await inventoryWorker.stop()
    }

    private func workspaceDidChange(pid: Int32?) {
        workspaceRevision &+= 1
        workspaceNeedsRefresh = true
        if let pid { invalidateInventory(pid: pid) } else { invalidateAllInventory() }
        // Refresh on the notification path, before the next shortcut asks for rows.
        if workspaceRefresh == nil {
            Task { [weak self] in _ = await self?.refreshWorkspaceSnapshot() }
        }
    }

    private func refreshWorkspaceSnapshot() async -> [ApplicationSnapshot] {
        if let workspaceRefresh { return await workspaceRefresh.value }
        let revision = workspaceRevision
        let token = UUID(); workspaceRefreshToken = token
        let task = Task { @MainActor in Self.applicationSnapshots() }
        workspaceRefresh = task
        let applications = await task.value
        guard workspaceRefreshToken == token else { return workspaceCache }
        workspaceCache = applications
        workspaceCacheUpdated = Date()
        inventoryPublishRevision &+= 1
        workspaceNeedsRefresh = workspaceRevision != revision
        workspaceRefresh = nil
        inventoryWake?.yield(())
        return applications
    }

    private func cachedWorkspaceSnapshot(currentPID: Int32? = nil, ownPID: Int32? = nil) async -> [ApplicationSnapshot] {
        let now = Date()
        if workspaceCacheUpdated == .distantPast { return await refreshWorkspaceSnapshot() }
        if let currentPID, currentPID != ownPID,
           !workspaceCache.contains(where: { $0.pid == currentPID }),
           now.timeIntervalSince(missingWorkspacePIDProbe[currentPID] ?? .distantPast) >= 1 {
            // AX/Workspace notifications can trail an application's first shortcut.
            missingWorkspacePIDProbe[currentPID] = now
            if missingWorkspacePIDProbe.count > 64 {
                missingWorkspacePIDProbe = missingWorkspacePIDProbe.filter { now.timeIntervalSince($0.value) < 5 }
            }
            return await refreshWorkspaceSnapshot()
        }
        if maintenance == nil && (workspaceNeedsRefresh || now.timeIntervalSince(workspaceCacheUpdated) >= 3) {
            return await refreshWorkspaceSnapshot()
        }
        if workspaceNeedsRefresh || now.timeIntervalSince(workspaceCacheUpdated) >= 3,
           workspaceRefresh == nil {
            Task { [weak self] in _ = await self?.refreshWorkspaceSnapshot() }
        }
        return workspaceCache
    }

    private func invalidateInventory(pid: Int32) {
        dirtyPIDs.insert(pid)
        inventoryRevision[pid, default: 0] &+= 1
        inventoryWake?.yield(())
    }

    private func wakeInventory() { inventoryWake?.yield(()) }

    private func invalidateAllInventory() {
        for pid in inventory.keys { invalidateInventory(pid: pid) }
    }

    private func maintainOneApplication() async -> Bool {
        guard !Task.isCancelled, AXIsProcessTrusted() else { return false }
        let apps = await cachedWorkspaceSnapshot().filter { $0.pid != ProcessInfo.processInfo.processIdentifier }
        let alive = Set(apps.map(\.pid))
        for pid in inventory.keys where !alive.contains(pid) { removeInventory(pid: pid) }
        await inventoryWorker.removeTerminated(alive)
        let now = Date()
        let due = apps.filter {
            let retryDelay = unreachablePIDs.contains($0.pid) ? 15.0 : 0.25
            return now.timeIntervalSince(inventoryAttempted[$0.pid] ?? .distantPast) >= retryDelay
                && (inventory[$0.pid] == nil || dirtyPIDs.contains($0.pid)
                    || now.timeIntervalSince(inventoryUpdated[$0.pid] ?? .distantPast) >= 30)
        }.sorted {
            if dirtyPIDs.contains($0.pid) != dirtyPIDs.contains($1.pid) { return dirtyPIDs.contains($0.pid) }
            return (inventoryAttempted[$0.pid] ?? .distantPast) < (inventoryAttempted[$1.pid] ?? .distantPast)
        }
        guard let app = due.first else {
            let delays = apps.filter { dirtyPIDs.contains($0.pid) }.map {
                max(0.05, (unreachablePIDs.contains($0.pid) ? 15.0 : 0.25)
                    - now.timeIntervalSince(inventoryAttempted[$0.pid] ?? .distantPast))
            }
            if delayedInventoryWake == nil, let delay = delays.min(), maintenance != nil {
                let generation = maintenanceGeneration
                delayedInventoryWake = Task.detached(priority: .background) { [weak self] in
                    do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                    await self?.deliverDelayedInventoryWake(generation)
                }
            }
            return false
        }
        _ = await refreshInventory(app)
        return true
    }

    private func deliverDelayedInventoryWake(_ generation: UUID) {
        guard maintenanceGeneration == generation else { return }
        delayedInventoryWake = nil
        inventoryWake?.yield(())
    }

    private func removeInventory(pid: Int32) {
        recency.removeProcess(pid)
        closedWindowIDs = closedWindowIDs.filter { $0.value != pid }
        inventory[pid] = nil; inventoryUpdated[pid] = nil; inventoryAttempted[pid] = nil
        inventoryClassifiedCGIDs[pid] = nil; inventoryPublishRevision &+= 1
        inventoryRevision[pid] = nil; dirtyPIDs.remove(pid); unreachablePIDs.remove(pid)
        let ids = elementPIDs.filter { $0.value == pid }.map(\.key)
        for id in ids { elements[id] = nil; elementPIDs[id] = nil }
    }

    private func refreshInventory(_ app: ApplicationSnapshot) async -> Bool {
        if refreshingPIDs.contains(app.pid) {
            while refreshingPIDs.contains(app.pid) {
                do { try await Task.sleep(for: .milliseconds(10)) } catch { return false }
            }
            return inventoryUpdated[app.pid] != nil
        }
        refreshingPIDs.insert(app.pid)
        defer { refreshingPIDs.remove(app.pid) }
        let revision = inventoryRevision[app.pid, default: 0]
        let cgIDsAtStart = Set(Self.compositorWindows().filter { $0.pid == app.pid }.map(\.id))
        dirtyPIDs.remove(app.pid)
        inventoryAttempted[app.pid] = Date()
        let batch = await inventoryWorker.scan(pid: app.pid, observe: maintenance != nil) { [weak self] pid, closedID, focusChanged in
            Task {
                if let closedID { await self?.forgetWindow(pid: pid, id: closedID) }
                await self?.invalidateInventory(pid: pid)
                if focusChanged { await self?.recordForegroundWindow(pid: pid) }
            }
        }
        workloadScans += 1; workloadAXBatches += batch.batchCalls; workloadAXFallbacks += batch.fallbackCalls
        guard !Task.isCancelled, inventoryRevision[app.pid, default: 0] == revision else {
            dirtyPIDs.insert(app.pid)
            return false
        }
        if !batch.complete && batch.batchCalls == 0 {
            unreachablePIDs.insert(app.pid)
        } else { unreachablePIDs.remove(app.pid) }
        var rows = inventory[app.pid] ?? [:]
        let knownWindowIDs = Set(rows.values.compactMap(\.windowID))
        if batch.records.contains(where: { record in
            record.windowID.map { !knownWindowIDs.contains($0) && shareable[$0] == nil } == true
        }) { shareableUpdated = .distantPast }
        for record in batch.records {
            if let id = record.windowID { closedWindowIDs[id] = nil }
            let id = rows[record.token]?.id
                ?? record.windowID.map { "ax:\(app.pid):\($0)" }
                ?? "ax:\(app.pid):\(record.token)"
            rows[record.token] = InventoryMetadata(id: id, windowID: record.windowID, title: record.title,
                frame: record.frame, subrole: record.subrole, minimized: record.minimized, fullscreen: record.fullscreen)
        }
        if batch.complete {
            // A completed AX window list is authoritative. A closed application
            // can retain compositor surfaces, which are not switchable windows.
            let missing = rows.filter { !batch.seenTokens.contains($0.key) }.values.compactMap(\.windowID)
            rows = rows.filter { batch.seenTokens.contains($0.key) }
            for id in missing { forgetWindow(pid: app.pid, id: id) }
            let retained = Set(rows.values.map(\.id))
            for (id, pid) in elementPIDs where pid == app.pid && !retained.contains(id) {
                elements[id] = nil; elementPIDs[id] = nil
            }
            inventoryUpdated[app.pid] = Date()
            inventoryClassifiedCGIDs[app.pid] = cgIDsAtStart
        } else { dirtyPIDs.insert(app.pid) }
        inventory[app.pid] = rows
        inventoryPublishRevision &+= 1
        return batch.complete
    }

    func discover(_ query: WindowQuery, cachedOnly: Bool = false) async -> [WindowItem] {
        let began = Date()
        if !cachedOnly, let currentPID = query.currentPID { await recordForegroundWindow(pid: currentPID) }
        let applications = await cachedWorkspaceSnapshot(currentPID: query.currentPID, ownPID: query.ownPID)
        let workspaceMS = Date().timeIntervalSince(began) * 1000
        guard !Task.isCancelled else { return [] }
        let cgBegan = Date()
        let compositor = Self.compositorWindows()
        let cgMS = Date().timeIntervalSince(cgBegan) * 1000
        let candidates = applications.filter { app in
            app.pid != query.ownPID && !query.excludedBundleIDs.contains(app.bundleID)
                && (query.allowedPIDs?.contains(app.pid) ?? true)
                && (query.includeHidden || !app.hidden)
                && (query.mode != .currentApplication || app.pid == query.currentPID)
                && !query.excludedWindowRules.contains { $0.isEnabled && $0.bundleID == app.bundleID && $0.titlePattern == "*" }
        }
        let trusted = AXIsProcessTrusted()
        var foregroundScans = 0
        // Startup is warmed independently of popup requests. A genuinely cold caller
        // still gets a complete AX inventory rather than guessing minimized states.
        let coldDeadline = Date().addingTimeInterval(6)
        if trusted && maintenance == nil && !cachedOnly {
            for app in candidates where inventory[app.pid] == nil
                || (maintenance == nil && (dirtyPIDs.contains(app.pid)
                    || Date().timeIntervalSince(inventoryUpdated[app.pid] ?? .distantPast) > 0.1)) {
                repeat {
                    foregroundScans += 1
                    let complete = await refreshInventory(app)
                    if complete || unreachablePIDs.contains(app.pid) || Task.isCancelled || Date() >= coldDeadline { break }
                } while inventoryUpdated[app.pid] == nil
                if Task.isCancelled || Date() >= coldDeadline { break }
            }
        }
        let byID = Dictionary(compositor.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let byPID = Dictionary(grouping: compositor, by: \.pid)
        var result: [WindowItem] = []
        var provisionalRows = 0
        var pendingClassification = 0
        for app in candidates {
            var rows: [WindowItem] = []
            if trusted {
                for cached in (inventory[app.pid] ?? [:]).values {
                    if cached.windowID.map({ closedWindowIDs[$0] == app.pid }) == true { continue }
                    if !query.includeMinimized && cached.minimized { continue }
                    if !query.includePalettes && [kAXFloatingWindowSubrole, kAXSystemFloatingWindowSubrole].contains(cached.subrole) { continue }
                    let live = cached.windowID.flatMap { byID[$0] }
                    let frame = live?.frame ?? cached.frame
                    let onScreen = live?.onScreen ?? false
                    guard query.allSpaces || onScreen,
                          query.allScreens || query.screenBounds.map({ $0.intersects(frame) }) != false else { continue }
                    let item = WindowItem(id: cached.id, windowID: cached.windowID, pid: app.pid,
                        appName: app.name, bundleID: app.bundleID,
                        title: live.flatMap { $0.title.isEmpty ? nil : $0.title } ?? cached.title,
                        frame: frame, isMinimized: cached.minimized, isHidden: app.hidden,
                        isOnScreen: onScreen, isFullscreen: cached.fullscreen)
                    if !WindowRule.excludes(item, rules: query.excludedWindowRules) { rows.append(item) }
                }
                if maintenance != nil || cachedOnly {
                    let metadataIDs = Set((inventory[app.pid] ?? [:]).values.compactMap(\.windowID))
                    let classifiedIDs = inventoryClassifiedCGIDs[app.pid] ?? []
                    for live in byPID[app.pid] ?? [] where !metadataIDs.contains(live.id)
                        && !classifiedIDs.contains(live.id) && closedWindowIDs[live.id] != app.pid
                        && live.layer == 0 && live.frame.width >= 40 && live.frame.height >= 30 {
                        pendingClassification += 1
                        // A composited onscreen window is not minimized. Other-Space
                        // and hidden windows stay pending until AX can classify them,
                        // unless the caller explicitly includes minimized windows.
                        guard query.includeMinimized || live.onScreen,
                              query.allSpaces || live.onScreen,
                              query.allScreens || query.screenBounds.map({ $0.intersects(live.frame) }) != false else { continue }
                        let item = WindowItem(id: "ax:\(app.pid):\(live.id)", windowID: live.id, pid: app.pid,
                            appName: app.name, bundleID: app.bundleID, title: live.title.isEmpty ? app.name : live.title,
                            frame: live.frame, isHidden: app.hidden, isOnScreen: live.onScreen)
                        guard !WindowRule.excludes(item, rules: query.excludedWindowRules) else { continue }
                        rows.append(item); provisionalRows += 1
                    }
                }
            } else {
                rows = (byPID[app.pid] ?? []).filter { row in
                    (query.includePalettes || row.layer == 0) && row.frame.width >= 40 && row.frame.height >= 30
                        && (query.allSpaces || row.onScreen)
                        && (query.allScreens || query.screenBounds.map { $0.intersects(row.frame) } != false)
                }.map { row in
                    WindowItem(id: "cg:\(app.pid):\(row.id)", windowID: row.id, pid: app.pid,
                        appName: app.name, bundleID: app.bundleID, title: row.title.isEmpty ? app.name : row.title,
                        frame: row.frame, isHidden: app.hidden, isOnScreen: row.onScreen)
                }.filter { !WindowRule.excludes($0, rules: query.excludedWindowRules) }
            }
            rows.sort { (byID[$0.windowID ?? 0]?.order ?? .max) < (byID[$1.windowID ?? 0]?.order ?? .max) }
            rows = recency.ordered(rows)
            if query.mode == .applications {
                let first = rows.first
                result.append(WindowItem(id: "app:\(app.pid)", windowID: first?.windowID, pid: app.pid,
                    appName: app.name, bundleID: app.bundleID, title: app.name, frame: first?.frame ?? .zero,
                    isHidden: app.hidden, isOnScreen: first?.isOnScreen ?? false))
            } else { result += rows }
        }
        let launches = Dictionary(candidates.map { ($0.pid, $0.launched) }, uniquingKeysWith: { first, _ in first })
        result.sort { left, right in
            let lhs = byID[left.windowID ?? 0]?.order ?? .max, rhs = byID[right.windowID ?? 0]?.order ?? .max
            if lhs != rhs { return lhs < rhs }
            if left.pid != right.pid, launches[left.pid] != launches[right.pid] {
                return (launches[left.pid] ?? .distantPast) > (launches[right.pid] ?? .distantPast)
            }
            return left.id < right.id
        }
        result = recency.ordered(result)
        // Diagnostics: visible windows of candidate apps that this query left out, and why.
        let returnedIDs = Set(result.compactMap(\.windowID))
        let candidatePIDs = Set(candidates.map(\.pid))
        let dropped: [String] = compositor.compactMap { live in
            guard candidatePIDs.contains(live.pid), live.onScreen, live.layer == 0, live.frame.width >= 40, live.frame.height >= 30,
                  !returnedIDs.contains(live.id),
                  query.allScreens || query.screenBounds.map({ $0.intersects(live.frame) }) != false else { return nil }
            let inInventory = (inventory[live.pid] ?? [:]).values.contains { $0.windowID == live.id }
            let classified = inventoryClassifiedCGIDs[live.pid]?.contains(live.id) == true
            return "\(live.pid):\(live.id) inventory=\(inInventory) classified=\(classified) closed=\(closedWindowIDs[live.id] != nil)"
        }
        lastDiscoveryEvidence = ["strategy": "inventory-cache", "totalMS": Date().timeIntervalSince(began) * 1000,
            "droppedOnScreen": dropped,
            "workspaceMS": workspaceMS, "compositorMS": cgMS, "candidateApplications": candidates.count,
            "windowCount": result.count, "foregroundAXScans": foregroundScans,
            "inventoryComplete": candidates.allSatisfy { inventoryUpdated[$0.pid] != nil },
            "metadataComplete": candidates.allSatisfy { inventoryUpdated[$0.pid] != nil } && pendingClassification == 0
                && !workspaceNeedsRefresh && workspaceRefresh == nil,
            "provisionalRows": provisionalRows, "pendingClassification": pendingClassification,
            "inventoryRevision": inventoryPublishRevision,
            "workloadScans": workloadScans, "AXBatchCalls": workloadAXBatches, "AXScalarFallbackCalls": workloadAXFallbacks, "SCKRefreshes": workloadSCKRefreshes]
        return result
    }

    /// Runs inside the installed authorized app. It performs read-only enumeration;
    /// no window activation, keyboard/mouse injection, or user titles are exported.
    func benchmarkDiscovery(iterations: Int = 7) async -> Data {
        await stopBackgroundMaintenance()
        var query = WindowQuery(); query.ownPID = ProcessInfo.processInfo.processIdentifier
        var measurements: [[String: Any]] = []
        _ = await discoverLegacy(query)
        var legacy = lastDiscoveryEvidence; legacy["sample"] = "legacy-cold"; measurements.append(legacy)
        inventory.removeAll(); inventoryUpdated.removeAll(); inventoryAttempted.removeAll(); dirtyPIDs.removeAll()
        _ = await discover(query)
        var cold = lastDiscoveryEvidence; cold["sample"] = "new-cold"; measurements.append(cold)
        inventory.removeAll(); inventoryUpdated.removeAll(); inventoryAttempted.removeAll()
        inventoryClassifiedCGIDs.removeAll(); dirtyPIDs.removeAll()
        await startBackgroundMaintenance()
        _ = await discover(query)
        var interactive = lastDiscoveryEvidence; interactive["sample"] = "new-interactive-cold"; measurements.append(interactive)
        // Same background worker and observer path as normal startup. Completeness
        // is retained on every sample; provisional results are never called exact.
        for _ in 0..<40 {
            if lastDiscoveryEvidence["metadataComplete"] as? Bool == true { break }
            try? await Task.sleep(for: .milliseconds(100))
            _ = await discover(query)
        }
        var warmMS: [Double] = []
        for index in 0..<min(max(iterations, 3), 15) {
            _ = await discover(query)
            var sample = lastDiscoveryEvidence; sample["sample"] = "new-warm-\(index)"; measurements.append(sample)
            warmMS.append(sample["totalMS"] as? Double ?? 0)
            try? await Task.sleep(for: .milliseconds(80))
        }
        await stopBackgroundMaintenance()
        let sorted = warmMS.sorted()
        func percentile(_ fraction: Double) -> Double { sorted[min(Int(ceil(Double(sorted.count) * fraction)) - 1, sorted.count - 1)] }
        let report: [String: Any] = ["status": AXIsProcessTrusted() ? "measured" : "blocked", "accessibility": AXIsProcessTrusted(), "screenCapture": CGPreflightScreenCaptureAccess(),
            "warmP50MS": percentile(0.5), "warmP95MS": percentile(0.95), "samples": measurements,
            "limitations": "Legacy is capped at 5s; explicit new cold at 6s. Interactive cold never waits for AX. budgetExceeded/metadataComplete/provisionalRows make incomplete samples explicit. Warm samples use normal background maintenance."]
        return (try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    private func discoverLegacy(_ query: WindowQuery) async -> [WindowItem] {
        let began = Date()
        let deadline = began.addingTimeInterval(5)
        var appSamples: [[String: Double]] = []
        let applications = await Self.applicationSnapshots()
        guard !Task.isCancelled else { return [] }
        let compositor = Self.compositorWindows()
        let candidates = applications.filter { application in
            application.pid != query.ownPID && !query.excludedBundleIDs.contains(application.bundleID)
                && (query.includeHidden || !application.hidden)
                && (query.mode != .currentApplication || application.pid == query.currentPID)
                && !query.excludedWindowRules.contains(where: { rule in
                    rule.isEnabled && rule.bundleID == application.bundleID && rule.titlePattern == "*"
                })
        }
        let trusted = AXIsProcessTrusted()
        var result: [WindowItem] = []
        var retainedIDs: Set<String> = []

        for application in candidates {
            guard !Task.isCancelled, Date() < deadline else { break }
            let appBegan = Date()
            defer { appSamples.append(["pid": Double(application.pid), "ms": Date().timeIntervalSince(appBegan) * 1000]) }
            let cgWindows = compositor.filter { $0.pid == application.pid }
            let root = AXUIElementCreateApplication(application.pid)
            AXUIElementSetMessagingTimeout(root, 0.12)
            let windows = trusted ? Self.windows(of: root) : []
            var appWindows: [WindowItem] = []
            var assignedCompositorIDs: Set<UInt32> = []

            for element in windows {
                guard Date() < deadline else { break }
                AXUIElementSetMessagingTimeout(element, 0.12)
                let role = Self.string(kAXRoleAttribute, of: element)
                guard role == kAXWindowRole else { continue }
                let subrole = Self.string(kAXSubroleAttribute, of: element)
                if !query.includePalettes,
                   [kAXFloatingWindowSubrole, kAXSystemFloatingWindowSubrole].contains(subrole) {
                    continue
                }
                let minimized = Self.boolean(kAXMinimizedAttribute, of: element)
                guard query.includeMinimized || !minimized else { continue }
                let title = Self.string(kAXTitleAttribute, of: element)
                let frame = Self.frame(of: element)
                guard frame.width >= 40, frame.height >= 30 else { continue }
                let matching = Self.match(element, title: title, frame: frame,
                                          candidates: cgWindows.filter {
                                              !assignedCompositorIDs.contains($0.id)
                                          })
                if let matching { assignedCompositorIDs.insert(matching.id) }
                let onScreen = matching?.onScreen ?? false
                guard query.allSpaces || onScreen else { continue }
                guard query.allScreens || query.screenBounds.map({
                    $0.intersects(frame)
                }) != false else { continue }

                let id = stableID(for: element, pid: application.pid, windowID: matching?.id)
                let item = WindowItem(
                    id: id, windowID: matching?.id, pid: application.pid,
                    appName: application.name, bundleID: application.bundleID,
                    title: title.isEmpty ? application.name : title, frame: frame,
                    isMinimized: minimized, isHidden: application.hidden,
                    isOnScreen: onScreen,
                    isFullscreen: Self.boolean("AXFullScreen", of: element)
                )
                guard !WindowRule.excludes(item, rules: query.excludedWindowRules) else { continue }
                elements[id] = element
                elementPIDs[id] = application.pid
                retainedIDs.insert(id)
                appWindows.append(item)
            }

            // Without AX permission the compositor still supplies a useful list.
            // Window actions remain unavailable until their AX identity is known.
            if !trusted {
                appWindows = cgWindows.filter { row in
                    (query.includePalettes || row.layer == 0)
                        && row.frame.width >= 40 && row.frame.height >= 30
                        && (query.allSpaces || row.onScreen)
                        && (query.allScreens || query.screenBounds.map { $0.intersects(row.frame) } != false)
                }.map {
                    WindowItem(id: "cg:\(application.pid):\($0.id)", windowID: $0.id,
                               pid: application.pid, appName: application.name,
                               bundleID: application.bundleID,
                               title: $0.title.isEmpty ? application.name : $0.title,
                               frame: $0.frame, isHidden: application.hidden,
                               isOnScreen: $0.onScreen)
                }.filter { !WindowRule.excludes($0, rules: query.excludedWindowRules) }
            }

            appWindows.sort { Self.order($0, compositor: compositor) < Self.order($1, compositor: compositor) }
            if query.mode == .applications {
                let first = appWindows.first
                // Application mode also includes regular applications with no windows.
                result.append(WindowItem(
                    id: "app:\(application.pid)", windowID: first?.windowID,
                    pid: application.pid, appName: application.name,
                    bundleID: application.bundleID, title: application.name,
                    frame: first?.frame ?? .zero, isHidden: application.hidden,
                    isOnScreen: first?.isOnScreen ?? false
                ))
            } else {
                result.append(contentsOf: appWindows)
            }
        }

        // Legacy benchmark mirrors the old query-scoped handle retention.
        elements = elements.filter { retainedIDs.contains($0.key) }
        elementPIDs = elementPIDs.filter { retainedIDs.contains($0.key) }
        let launchDates = Dictionary(candidates.map { ($0.pid, $0.launched) }, uniquingKeysWith: { first, _ in first })
        lastDiscoveryEvidence = ["strategy": "legacy", "totalMS": Date().timeIntervalSince(began) * 1000, "candidateApplications": candidates.count, "windowCount": result.count, "budgetExceeded": Date() >= deadline, "perApplication": appSamples]
        return result.sorted { leftItem, rightItem in
            let left = Self.order(leftItem, compositor: compositor)
            let right = Self.order(rightItem, compositor: compositor)
            if left != right { return left < right }
            if leftItem.pid != rightItem.pid {
                let l = launchDates[leftItem.pid] ?? .distantPast
                let r = launchDates[rightItem.pid] ?? .distantPast
                if l != r { return l > r }
            }
            return leftItem.id < rightItem.id
        }
    }

    func thumbnail(windowID: UInt32, maxSize: Int, interpolationQuality: Int = 4) async -> CGImage? {
        let limit = min(max(maxSize, 1), 1920)
        return await thumbnail(windowID: windowID, maxPixelSize: CGSize(width: limit, height: limit), interpolationQuality: interpolationQuality)
    }

    func thumbnail(windowID: UInt32, maxPixelSize: CGSize, interpolationQuality: Int = 4, refresh: Bool = false,
                   mayCapture: @escaping @Sendable () -> Bool = { true }) async -> CGImage? {
        guard CGPreflightScreenCaptureAccess(), !Task.isCancelled,
              maxPixelSize.width.isFinite, maxPixelSize.height.isFinite else { return nil }
        let key = ThumbnailKey(windowID: windowID, width: Int(min(max(maxPixelSize.width, 1), 4096)),
                               height: Int(min(max(maxPixelSize.height, 1), 4096)),
                               quality: interpolationQuality == 2 ? 2 : 4, fullRetina: nil)
        return await cachedThumbnail(key, refresh: refresh, mayCapture: mayCapture)
    }

    func fullWindowPreview(windowID: UInt32, allowRetina: Bool, interpolationQuality: Int = 4) async -> CGImage? {
        guard CGPreflightScreenCaptureAccess(), !Task.isCancelled else { return nil }
        return await cachedThumbnail(ThumbnailKey(windowID: windowID, width: 0, height: 0,
                                                  quality: interpolationQuality == 2 ? 2 : 4, fullRetina: allowRetina))
    }

    private func cachedThumbnail(_ key: ThumbnailKey, refresh: Bool = false,
                                 mayCapture: @escaping @Sendable () -> Bool = { true }) async -> CGImage? {
        if !refresh, let cached = thumbnails[key], key.fullRetina == nil || Date().timeIntervalSince(cached.updated) < 2 {
            return cached.image
        }
        if let existing = pendingThumbnails[key] { return await existing.value }
        guard pendingThumbnails.count < 32 else { return nil }
        // Keep an old image available while a background refresh is in flight.
        let task = Task(priority: refresh ? .background : Task.currentPriority) { await self.capture(key, background: refresh, mayCapture: mayCapture) }
        pendingThumbnails[key] = task
        let image = await task.value
        pendingThumbnails[key] = nil
        guard let image else { return nil }
        thumbnails[key] = (image, Date())
        // Bound both row previews and larger hover previews by actual pixels.
        while thumbnails.count > 32 || thumbnails.values.reduce(0, { $0 + $1.image.width * $1.image.height }) > 24_000_000 {
            guard let oldest = thumbnails.min(by: { $0.value.updated < $1.value.updated })?.key else { break }
            thumbnails[oldest] = nil
        }
        return image
    }

    /// Call when dismissing a switcher to stop captures queued for an old session.
    func invalidateThumbnail(windowID: UInt32) {
        thumbnails = thumbnails.filter { $0.key.windowID != windowID }
    }

    func cancelPendingThumbnails() {
        for task in pendingThumbnails.values { task.cancel() }
    }

    func perform(_ action: WindowAction, on item: WindowItem) async -> Bool {
        if action == .focus, isWindowMissing(item) { return false }
        defer {
            if action != .focus, item.pid > 0 { invalidateInventory(pid: item.pid) }
            if action == .hideApplication || action == .quitApplication || action == .forceQuitApplication
                || (action == .focus && item.isHidden) {
                workspaceDidChange(pid: item.pid)
            }
        }
        if action == .focus {
            lastFocusEvidence = ["activationStage": "service-entry", "activationPID": "\(item.pid)",
                                 "activationWindowID": item.windowID.map(String.init) ?? "none",
                                 "singleWindowFocus": "\(singleWindowFocus)"]
            lastFocusEvidence["taskCancelled"] = "\(Task.isCancelled)"
            lastFocusEvidence["AXTrusted"] = "\(AXIsProcessTrusted())"
        }
        if let url = item.documentURL {
            guard action == .focus, !Task.isCancelled else { return false }
            return await Self.openDocument(url)
        }
        guard !Task.isCancelled else { return false }
        if action == .newWindow || action == .newTab || action == .openFile {
            return await sendCreationShortcut(action, to: item)
        }
        if action == .quitApplication {
            guard await Self.applicationAction(action, pid: item.pid, bundleID: item.bundleID) else { return false }
            for _ in 0..<10 {
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return false }
                if await Self.hasTerminated(pid: item.pid, bundleID: item.bundleID) { return true }
            }
            _ = await Self.applicationAction(.focus, pid: item.pid, bundleID: item.bundleID)
            return false
        }
        if action == .hideApplication || action == .forceQuitApplication {
            return await Self.applicationAction(action, pid: item.pid, bundleID: item.bundleID)
        }
        if action == .bringToCurrentSpace {
            guard AXIsProcessTrusted() else { return false }
            let target = item.id.hasPrefix("app:")
                ? item.windowID.flatMap { SingleWindowActivation.element(pid: item.pid, windowID: $0) }
                : liveElement(for: item)
            guard let target, let id = SingleWindowActivation.windowID(for: target) ?? item.windowID,
                  !Task.isCancelled, await SpaceService.moveToCurrent(windowID: id) else { return false }
            return await perform(.focus, on: item)
        }
        if item.id.hasPrefix("app:") {
            guard action == .focus else { return false }
            if singleWindowFocus, let id = item.windowID {
                guard AXIsProcessTrusted(), SingleWindowActivation.available,
                      let element = SingleWindowActivation.element(pid: item.pid, windowID: id) else { return false }
                return focusSingle(item, windowID: id, element: element)
            }
            if singleWindowFocus, Self.compositorWindows().contains(where: {
                $0.pid == item.pid && $0.layer == 0 && $0.frame.width >= 40 && $0.frame.height >= 30
            }) {
                // A filtered application row can have no eligible preview while
                // its other-display windows still exist. Do not raise all of them.
                return false
            }
            return await Self.applicationAction(.focus, pid: item.pid, bundleID: item.bundleID)
        }
        guard AXIsProcessTrusted() else {
            if action == .focus { lastFocusEvidence["activationStage"] = "permission" }
            return false
        }
        let resolved = if action == .focus { await focusElement(for: item) } else { liveElement(for: item) }
        if action == .focus { lastFocusEvidence.merge(lastLookupEvidence, uniquingKeysWith: { _, value in value }) }
        guard let element = resolved, !Task.isCancelled else {
            if action == .focus, lastLookupEvidence["lookupStrategy"] == "confirmed-absent", let id = item.windowID {
                forgetWindow(pid: item.pid, id: id)
            }
            if action == .focus { lastFocusEvidence["activationStage"] = "AX-window-identity" }
            return false
        }

        switch action {
        case .focus:
            if Self.boolean(kAXMinimizedAttribute, of: element) {
                guard AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString,
                                                   kCFBooleanFalse) == .success else { return false }
            }
            if singleWindowFocus {
                guard SingleWindowActivation.available,
                      let id = SingleWindowActivation.windowID(for: element) ?? item.windowID else { return false }
                return focusSingle(item, windowID: id, element: element)
            }
            guard await Self.applicationAction(.focus, pid: item.pid,
                                                bundleID: item.bundleID) else { return false }
            // The app may have exited or replaced a window during activation.
            guard let current = liveElement(for: item) else { return false }
            let root = AXUIElementCreateApplication(item.pid)
            AXUIElementSetMessagingTimeout(root, 0.12)
            _ = AXUIElementSetAttributeValue(current, kAXMainAttribute as CFString, kCFBooleanTrue)
            _ = AXUIElementSetAttributeValue(root, kAXFocusedWindowAttribute as CFString, current)
            let raised = AXUIElementPerformAction(current, kAXRaiseAction as CFString) == .success
            if raised, let id = SingleWindowActivation.windowID(for: current) { recordFocus(pid: item.pid, windowID: id) }
            return raised
        case .close:
            guard let close = Self.element(kAXCloseButtonAttribute, of: element) else { return false }
            guard AXUIElementPerformAction(close, kAXPressAction as CFString) == .success else { return false }
            for _ in 0..<6 {
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return false }
                if liveElement(for: item) == nil && lastLookupEvidence["lookupStrategy"] == "confirmed-absent"
                    && Self.compositorOwnerPresent(for: item) == false {
                    inventory[item.pid] = inventory[item.pid]?.filter { $0.value.id != item.id }
                    return true
                }
            }
            // A document may be waiting for the user's save decision.
            _ = await perform(.focus, on: item)
            return false
        case .minimize:
            return AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString,
                Self.boolean(kAXMinimizedAttribute, of: element) ? kCFBooleanFalse : kCFBooleanTrue) == .success
        case .toggleFullscreen:
            return AXUIElementSetAttributeValue(element, "AXFullScreen" as CFString,
                Self.boolean("AXFullScreen", of: element) ? kCFBooleanFalse : kCFBooleanTrue) == .success
        case .center, .snapLeft, .snapRight, .maximize, .compact, .restore:
            return await layout(action, item: item, element: element)
        case .hideApplication, .quitApplication, .newWindow, .newTab,
             .bringToCurrentSpace, .forceQuitApplication, .openFile:
            return false
        }
    }

    private func focusSingle(_ item: WindowItem, windowID: UInt32, element: AXUIElement) -> Bool {
        lastFocusEvidence["activationStage"] = "prepare-window"
        if Self.boolean(kAXMinimizedAttribute, of: element) {
            let code = AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            lastFocusEvidence["unminimizeCode"] = "\(code.rawValue)"
            guard code == .success else { return false }
        }
        let result = SingleWindowActivation.focusDetailed(pid: item.pid, windowID: windowID, element: element)
        lastFocusEvidence.merge(result.evidence, uniquingKeysWith: { _, value in value })
        if result.accepted { recordFocus(pid: item.pid, windowID: windowID) }
        return result.accepted
    }

    private func sendCreationShortcut(_ action: WindowAction, to item: WindowItem) async -> Bool {
        guard await perform(.focus, on: item) else { return false }
        var frontmost = false
        for _ in 0..<10 {
            guard !Task.isCancelled else { return false }
            if await Self.isFrontmost(pid: item.pid, bundleID: item.bundleID) {
                frontmost = true
                break
            }
            do { try await Task.sleep(for: .milliseconds(30)) } catch { return false }
        }
        guard frontmost, !Task.isCancelled else { return false }
        if !item.id.hasPrefix("app:") {
            let root = AXUIElementCreateApplication(item.pid)
            AXUIElementSetMessagingTimeout(root, 0.12)
            guard let current = liveElement(for: item),
                  let focused = Self.element(kAXFocusedWindowAttribute, of: root),
                  CFEqual(current, focused) else { return false }
        }
        let key: CGKeyCode = switch action {
        case .newTab: 17 // ANSI T
        case .openFile: 31 // ANSI O
        default: 45 // ANSI N
        }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false) else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
        up.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
        down.postToPid(item.pid)
        up.postToPid(item.pid)
        return true
    }

    private func layout(_ action: WindowAction, item: WindowItem, element: AXUIElement) async -> Bool {
        let original = Self.frame(of: element)
        guard original.width > 0, original.height > 0 else { return false }
        if action == .restore {
            guard let saved = restoreFrames[item.id], let current = liveElement(for: item),
                  Self.setFrame(saved.frame, of: current) else { return false }
            restoreFrames[item.id] = nil
            return true
        }
        guard let area = await Self.layoutArea(for: original), !Task.isCancelled,
              let current = liveElement(for: item) else { return false }
        let target: CGRect
        switch action {
        case .center:
            let size = CGSize(width: min(original.width, area.width), height: min(original.height, area.height))
            target = CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                            width: size.width, height: size.height)
        case .snapLeft:
            target = CGRect(x: area.minX, y: area.minY, width: area.width / 2, height: area.height)
        case .snapRight:
            target = CGRect(x: area.midX, y: area.minY, width: area.width / 2, height: area.height)
        case .maximize: target = area
        case .compact:
            target = CGRect(x: area.minX + area.width / 6, y: area.minY + area.height / 8,
                            width: area.width * 2 / 3, height: area.height * 3 / 4)
        default: return false
        }
        // AX frame writes are separate operations; retain a restore point even
        // if an application accepts only part of the requested layout.
        if restoreFrames[item.id] == nil { restoreFrames[item.id] = (original, Date()) }
        if restoreFrames.count > 128, let oldest = restoreFrames.min(by: { $0.value.updated < $1.value.updated })?.key {
            restoreFrames[oldest] = nil
        }
        return Self.setFrame(target, of: current)
    }

    private static func setFrame(_ frame: CGRect, of element: AXUIElement) -> Bool {
        var origin = frame.origin
        var size = frame.size
        guard let position = AXValueCreate(.cgPoint, &origin), let dimensions = AXValueCreate(.cgSize, &size) else { return false }
        let first = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, position)
        let resized = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, dimensions)
        let moved = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, position)
        return first == .success && resized == .success && moved == .success
    }

    @MainActor private static func layoutArea(for frame: CGRect) -> CGRect? {
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        let screens = NSScreen.screens.map { screen -> (CGRect, CGRect) in
            let whole = screen.frame
            let visible = screen.visibleFrame
            return (CGRect(x: whole.minX, y: primaryHeight - whole.maxY, width: whole.width, height: whole.height),
                    CGRect(x: visible.minX, y: primaryHeight - visible.maxY, width: visible.width, height: visible.height))
        }
        return screens.max {
            let l = frame.intersection($0.0)
            let r = frame.intersection($1.0)
            return (l.isNull ? 0 : l.width * l.height) < (r.isNull ? 0 : r.width * r.height)
        }?.1
    }

    @MainActor private static func isFrontmost(pid: Int32, bundleID: String) -> Bool {
        let app = NSWorkspace.shared.frontmostApplication
        return app?.processIdentifier == pid && app?.bundleIdentifier ?? "" == bundleID
    }

    private func liveElement(for item: WindowItem) -> AXUIElement? {
        let root = AXUIElementCreateApplication(item.pid)
        AXUIElementSetMessagingTimeout(root, 0.12)
        var value: CFTypeRef?
        let code = AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &value)
        let current = value as? [AXUIElement]
        lastLookupEvidence = ["AXWindowsCode": "\(code.rawValue)", "AXWindowsCount": "\(current?.count ?? 0)",
                              "cachedPresent": "\(elements[item.id] != nil)", "lookupStrategy": "unavailable"]
        guard code == .success, let current else { return nil }
        if let id = item.windowID {
            let identity = Self.compositorIdentity(for: item)
            lastLookupEvidence["CGOwnerMatches"] = "\(identity.present && !identity.conflict)"
            lastLookupEvidence["CGOwnerConflict"] = "\(identity.conflict)"
            guard !identity.conflict else { return nil }
            let matches = current.filter { element in
                var pid: Int32 = 0
                return AXUIElementGetPid(element, &pid) == .success && pid == item.pid
                    && SingleWindowActivation.windowID(for: element) == id
            }
            lastLookupEvidence["nativeWindowIDMatches"] = "\(matches.count)"
            if matches.count == 1, let fresh = matches.first {
                elements[item.id] = fresh; elementPIDs[item.id] = item.pid
                lastLookupEvidence["lookupStrategy"] = "pid-and-windowID"
                return fresh
            }
        }
        if elementPIDs[item.id] == item.pid, let original = elements[item.id],
           let fresh = current.first(where: { CFEqual($0, original) }) {
            lastLookupEvidence["lookupStrategy"] = "current-CF-identity"
            return fresh
        }
        lastLookupEvidence["lookupStrategy"] = "confirmed-absent"
        return nil
    }

    private func focusElement(for item: WindowItem) async -> AXUIElement? {
        if let element = liveElement(for: item) { return element }
        if lastLookupEvidence["AXWindowsCode"] == "0", lastLookupEvidence["AXWindowsCount"] == "0" { return nil }
        guard Self.compositorOwnerPresent(for: item) == true || item.isMinimized || item.isHidden else { return nil }
        do { try await Task.sleep(for: .milliseconds(25)) } catch { return nil }
        guard !Task.isCancelled, AXIsProcessTrusted() else { return nil }
        let element = liveElement(for: item)
        lastLookupEvidence["boundedReadRetry"] = "true"
        return element
    }

    private static func compositorOwnerPresent(for item: WindowItem) -> Bool? {
        let identity = compositorIdentity(for: item)
        return identity.readable ? identity.present && !identity.conflict : nil
    }

    private static func compositorIdentity(for item: WindowItem) -> (present: Bool, conflict: Bool, readable: Bool) {
        guard let id = item.windowID, id != 0 else { return (false, false, false) }
        let specific = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]]
        var rows = specific
        if specific?.contains(where: { $0[kCGWindowNumber as String] as? UInt32 == id }) != true {
            rows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]]
        }
        guard let rows else { return (false, false, false) }
        guard let row = rows.first(where: { $0[kCGWindowNumber as String] as? UInt32 == id }) else {
            // Minimized/off-Space windows can be omitted; a fresh AX pid+ID
            // remains a valid identity. Absence is not an ownership conflict.
            return (false, false, true)
        }
        return (true, row[kCGWindowOwnerPID as String] as? Int32 != item.pid, true)
    }

    private func stableID(for element: AXUIElement, pid: Int32, windowID: UInt32?) -> String {
        if let existing = elements.first(where: {
            elementPIDs[$0.key] == pid && CFEqual($0.value, element)
        })?.key { return existing }
        if let windowID { return "ax:\(pid):\(windowID)" }
        return "ax:\(pid):\(UUID().uuidString)"
    }

    private func backgroundSchedulingEvidence() -> [String: String] {
        ["taskPriority": "\(Task.currentPriority.rawValue)", "threadQoS": "\(Thread.current.qualityOfService.rawValue)", "backend": "ScreenCaptureKit-background"]
    }

    private func capture(_ key: ThumbnailKey, background: Bool = false, mayCapture: @Sendable () -> Bool = { true }) async -> CGImage? {
        while activeCaptures >= 2 {
            do { try await Task.sleep(for: .milliseconds(40)) }
            catch { return nil }
        }
        guard !Task.isCancelled, mayCapture() else { return nil }
        activeCaptures += 1
        captureCount += 1
        defer { activeCaptures -= 1 }
        if captureEvidence.count >= 128 { captureEvidence.removeAll() }
        if background { captureEvidence[key.windowID] = backgroundSchedulingEvidence() }
        else {
            let original = await windowCaptureWorker.capture(key)
            guard !Task.isCancelled else { return nil }
            captureEvidence[key.windowID] = original.evidence
            if let image = original.image { return image }
        }
        if Date().timeIntervalSince(shareableUpdated) > 4 {
            if contentRefresh == nil {
                contentRefreshToken = UUID()
                contentRefresh = Task { await self.refreshShareable() }
            }
            if let refresh = contentRefresh {
                let token = contentRefreshToken
                await refresh.value
                if contentRefreshToken == token { contentRefresh = nil }
            }
        }
        guard let window = shareable[key.windowID], !Task.isCancelled, mayCapture() else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let width = max(Float32(window.frame.width), 1)
        let height = max(Float32(window.frame.height), 1)
        let scale: Float32
        if let retina = key.fullRetina { scale = retina ? 2 : 1 }
        else { scale = min(Float32(key.width) / width, Float32(key.height) / height) }
        config.width = max(Int(width * scale), 1)
        config.height = max(Int(height * scale), 1)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.ignoreGlobalClipSingleWindow = true
        if #available(macOS 14.2, *) { config.includeChildWindows = true }
        config.captureResolution = .nominal
        let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        if image != nil, !background { captureEvidence[key.windowID]?["backend"] = "ScreenCaptureKit-fallback" }
        return image
    }

    private func refreshShareable() async {
        workloadSCKRefreshes += 1
        let windows = (try? await SCShareableContent.excludingDesktopWindows(
            true, onScreenWindowsOnly: false))?.windows ?? []
        shareable = Dictionary(windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
        shareableUpdated = Date()
    }

    @MainActor
    private static func applicationSnapshots() -> [ApplicationSnapshot] {
        NSWorkspace.shared.runningApplications.compactMap {
            guard $0.activationPolicy == .regular, !$0.isTerminated else { return nil }
            return ApplicationSnapshot(pid: $0.processIdentifier,
                name: $0.localizedName ?? $0.bundleIdentifier ?? "Application",
                bundleID: $0.bundleIdentifier ?? "", hidden: $0.isHidden,
                launched: $0.launchDate ?? .distantPast)
        }
    }

    @MainActor
    private static func openDocument(_ url: URL) -> Bool {
        guard !Task.isCancelled, url.isFileURL, FileManager.default.fileExists(atPath: url.path) else { return false }
        return NSWorkspace.shared.open(url)
    }

    @MainActor
    private static func hasTerminated(pid: Int32, bundleID: String) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid), app.bundleIdentifier == bundleID else { return true }
        return app.isTerminated
    }

    @MainActor
    private static func applicationAction(_ action: WindowAction, pid: Int32, bundleID: String) -> Bool {
        guard !Task.isCancelled, let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
              app.bundleIdentifier ?? "" == bundleID else { return false }
        switch action {
        case .focus:
            if app.isHidden { app.unhide() }
            return app.activate(options: [])
        case .hideApplication: return app.hide()
        case .quitApplication: return app.terminate()
        case .forceQuitApplication: return app.forceTerminate()
        default: return false
        }
    }

    private static func compositorWindows() -> [CompositorWindow] {
        let rows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return rows.enumerated().compactMap { index, row in
            guard let id = row[kCGWindowNumber as String] as? UInt32,
                  let pid = row[kCGWindowOwnerPID as String] as? Int32,
                  let bounds = row[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
            return CompositorWindow(id: id, pid: pid,
                title: row[kCGWindowName as String] as? String ?? "", frame: frame,
                onScreen: row[kCGWindowIsOnscreen as String] as? Bool ?? false,
                order: index, layer: row[kCGWindowLayer as String] as? Int ?? 0)
        }
    }

    private static func order(_ item: WindowItem, compositor: [CompositorWindow]) -> Int {
        guard let id = item.windowID else { return Int.max }
        return compositor.first { $0.id == id }?.order ?? Int.max
    }

    private static func match(_ element: AXUIElement, title: String, frame: CGRect,
                              candidates: [CompositorWindow]) -> CompositorWindow? {
        if let id = SingleWindowActivation.windowID(for: element),
           let direct = candidates.first(where: { $0.id == id }) { return direct }
        // Some applications expose this optional attribute. It is not assumed to exist.
        if let number = value("AXWindowNumber", of: element) as? NSNumber,
           let direct = candidates.first(where: { $0.id == number.uint32Value }) { return direct }
        let geometric = candidates.filter {
            abs($0.frame.minX - frame.minX) < 3 && abs($0.frame.minY - frame.minY) < 3
                && abs($0.frame.width - frame.width) < 3 && abs($0.frame.height - frame.height) < 3
        }
        if geometric.count == 1 { return geometric.first }
        let named = geometric.filter { !$0.title.isEmpty && $0.title == title }
        if named.count == 1 { return named.first }
        let exactTitle = candidates.filter { !title.isEmpty && $0.title == title && $0.layer == 0 }
        return exactTitle.count == 1 ? exactTitle.first : nil
    }

    private static func value(_ attribute: String, of element: AXUIElement) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result
    }

    private static func string(_ attribute: String, of element: AXUIElement) -> String {
        value(attribute, of: element) as? String ?? ""
    }

    private static func boolean(_ attribute: String, of element: AXUIElement) -> Bool {
        value(attribute, of: element) as? Bool ?? false
    }

    private static func element(_ attribute: String, of parent: AXUIElement) -> AXUIElement? {
        guard let value = value(attribute, of: parent), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func windows(of app: AXUIElement) -> [AXUIElement] {
        value(kAXWindowsAttribute, of: app) as? [AXUIElement] ?? []
    }

    private static func frame(of element: AXUIElement) -> CGRect {
        guard let rawPosition = value(kAXPositionAttribute, of: element),
              let rawSize = value(kAXSizeAttribute, of: element),
              CFGetTypeID(rawPosition) == AXValueGetTypeID(),
              CFGetTypeID(rawSize) == AXValueGetTypeID() else { return .zero }
        let position = unsafeDowncast(rawPosition, to: AXValue.self)
        let size = unsafeDowncast(rawSize, to: AXValue.self)
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &point),
              AXValueGetValue(size, .cgSize, &dimensions) else { return .zero }
        return CGRect(origin: point, size: dimensions)
    }
}

private nonisolated struct InventoryMetadata {
    let id: String
    let windowID: UInt32?
    let title: String
    let frame: CGRect
    let subrole: String
    let minimized: Bool
    let fullscreen: Bool
}

// Only Sendable value metadata crosses from the background AX/observer actor.
// Actions resolve the exact PID/windowID and retain their own validated AX handle.
private nonisolated struct InventoryRecord: Sendable {
    let token: String
    let windowID: UInt32?
    let title: String
    let frame: CGRect
    let subrole: String
    let minimized: Bool
    let fullscreen: Bool
}
private nonisolated struct InventoryBatch: Sendable {
    let records: [InventoryRecord]
    let seenTokens: Set<String>
    let complete: Bool
    let batchCalls: Int
    let fallbackCalls: Int
}
private nonisolated final class InventoryNotificationContext: Sendable {
    let pid: Int32
    let windowID: UInt32?
    let invalidate: @Sendable (Int32, UInt32?, Bool) -> Void
    init(pid: Int32, windowID: UInt32? = nil, invalidate: @escaping @Sendable (Int32, UInt32?, Bool) -> Void) {
        self.pid = pid; self.windowID = windowID; self.invalidate = invalidate
    }
}

private actor WindowInventoryWorker {
    private struct Observation {
        let observer: AXObserver
        let root: AXUIElement
        let context: InventoryNotificationContext
        var windowContexts: [String: InventoryNotificationContext] = [:]
        var tokens: Set<String> = []
    }
    private var observations: [Int32: Observation] = [:]
    private var cursor: [Int32: Int] = [:]
    private var seen: [Int32: Set<String>] = [:]

    func stop() {
        let contexts = observations.values.flatMap { [$0.context] + Array($0.windowContexts.values) }
        for observation in observations.values {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observation.observer), .commonModes)
        }
        observations.removeAll(); cursor.removeAll(); seen.removeAll()
        // refcon is not retained by AX. Keep it through a main-runloop barrier so
        // a callback already executing on that runloop cannot read freed memory.
        Task { @MainActor in withExtendedLifetime(contexts) {} }
    }
    func removeTerminated(_ alive: Set<Int32>) {
        for pid in observations.keys where !alive.contains(pid) {
            if let observation = observations.removeValue(forKey: pid) {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observation.observer), .commonModes)
                let contexts = [observation.context] + Array(observation.windowContexts.values)
                Task { @MainActor in withExtendedLifetime(contexts) {} }
            }
            cursor[pid] = nil; seen[pid] = nil
        }
    }
    func scan(pid: Int32, observe: Bool, invalidate: @escaping @Sendable (Int32, UInt32?, Bool) -> Void) -> InventoryBatch {
        let root = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(root, 0.04)
        if observe && observations[pid] == nil { installObserver(pid: pid, root: root, invalidate: invalidate) }
        var rawWindows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &rawWindows) == .success,
              let windows = rawWindows as? [AXUIElement] else {
            return InventoryBatch(records: [], seenTokens: [], complete: false, batchCalls: 0, fallbackCalls: 0)
        }
        var start = cursor[pid] ?? 0
        if start >= windows.count { start = 0 }
        if start == 0 { seen[pid] = [] }
        var batchCalls = 0, fallbackCalls = 0, next = start
        var records: [InventoryRecord] = []
        let deadline = Date().addingTimeInterval(0.45)
        let attributes = [kAXRoleAttribute, kAXSubroleAttribute, kAXMinimizedAttribute, kAXTitleAttribute,
                          kAXPositionAttribute, kAXSizeAttribute, "AXFullScreen"]
        for index in start..<windows.count {
            if Task.isCancelled || Date() >= deadline { break }
            next = index + 1
            let element = windows[index]
            AXUIElementSetMessagingTimeout(element, 0.025)
            let id = SingleWindowActivation.windowID(for: element)
            let token = id.map { "wid:\($0)" } ?? "axhash:\(CFHash(element))"
            // Preserve an existing row if only its optional attributes fail.
            seen[pid, default: []].insert(token)
            var values: CFArray?
            batchCalls += 1
            let code = AXUIElementCopyMultipleAttributeValues(element, attributes as CFArray,
                                                              AXCopyMultipleAttributeOptions(rawValue: 0), &values)
            var decoded: [String: Any] = [:]
            if code == .success, let values = values as? [Any], values.count == attributes.count {
                for (attribute, value) in zip(attributes, values) { decoded[attribute] = value }
            } else {
                // Some third-party apps do not implement the batch AX method.
                for attribute in attributes {
                    var value: CFTypeRef?
                    fallbackCalls += 1
                    if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
                       let value { decoded[attribute] = value }
                }
            }
            if let role = decoded[kAXRoleAttribute] as? String, role != kAXWindowRole { seen[pid]?.remove(token) }
            guard decoded[kAXRoleAttribute] as? String == kAXWindowRole else { continue }
            let frame = Self.frame(position: decoded[kAXPositionAttribute], size: decoded[kAXSizeAttribute])
            guard frame.width >= 40, frame.height >= 30 else { continue }
            records.append(InventoryRecord(token: token, windowID: id,
                title: decoded[kAXTitleAttribute] as? String ?? "", frame: frame,
                subrole: decoded[kAXSubroleAttribute] as? String ?? "",
                minimized: decoded[kAXMinimizedAttribute] as? Bool ?? false,
                fullscreen: decoded["AXFullScreen"] as? Bool ?? false))
            if observe, var observation = observations[pid], observation.tokens.insert(token).inserted {
                let context = observation.windowContexts[token]
                    ?? InventoryNotificationContext(pid: pid, windowID: id, invalidate: invalidate)
                observation.windowContexts[token] = context
                for name in [kAXUIElementDestroyedNotification, kAXTitleChangedNotification,
                             kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification, kAXResizedNotification] {
                    _ = AXObserverAddNotification(observation.observer, element, name as CFString,
                        Unmanaged.passUnretained(context).toOpaque())
                }
                observations[pid] = observation
            }
        }
        let complete = next >= windows.count
        cursor[pid] = complete ? 0 : next
        let seenTokens = seen[pid] ?? []
        if complete { observations[pid]?.tokens.formIntersection(seenTokens) }
        return InventoryBatch(records: records, seenTokens: seenTokens, complete: complete,
                              batchCalls: batchCalls, fallbackCalls: fallbackCalls)
    }
    private func installObserver(pid: Int32, root: AXUIElement, invalidate: @escaping @Sendable (Int32, UInt32?, Bool) -> Void) {
        let context = InventoryNotificationContext(pid: pid, invalidate: invalidate)
        var observer: AXObserver?
        let status = AXObserverCreate(pid, { _, _, notification, raw in
            guard let raw else { return }
            let context = Unmanaged<InventoryNotificationContext>.fromOpaque(raw).takeUnretainedValue()
            let name = notification as String
            context.invalidate(context.pid, name == kAXUIElementDestroyedNotification ? context.windowID : nil,
                name == kAXFocusedWindowChangedNotification || name == kAXMainWindowChangedNotification)
        }, &observer)
        guard status == .success, let observer else { return }
        for name in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification] {
            _ = AXObserverAddNotification(observer, root, name as CFString, Unmanaged.passUnretained(context).toOpaque())
        }
        observations[pid] = Observation(observer: observer, root: root, context: context)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }
    private static func frame(position: Any?, size: Any?) -> CGRect {
        guard let position = position as CFTypeRef?, let size = size as CFTypeRef?,
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return .zero }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeDowncast(size, to: AXValue.self), .cgSize, &dimensions) else { return .zero }
        return CGRect(origin: point, size: dimensions)
    }
}

@MainActor private final class WindowWorkspaceSignals {
    private var tokens: [NSObjectProtocol] = []
    init(invalidate: @escaping @Sendable (Int32?, Bool) -> Void) {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { notification in
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                invalidate(app?.processIdentifier, notification.name == NSWorkspace.didActivateApplicationNotification)
            })
        }
    }
    func stop() {
        for token in tokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        tokens.removeAll()
    }
}
