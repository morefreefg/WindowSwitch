import Foundation
import CoreGraphics
import ApplicationServices
import Darwin

nonisolated struct SpaceDestination: Sendable {
    let ordinal: Int
    let id: UInt64
    let name: String
}

/// Space ordinals follow WindowServer's display order, then each display's desktop order.
/// Fullscreen spaces are omitted. No mutation happens until `move` is called.
nonisolated enum SpaceService {
    private final class TraceStore: @unchecked Sendable {
        let lock = NSLock()
        var values: [UInt32: [String: String]] = [:]
    }
    private static let traces = TraceStore()
    static func diagnostics(windowID: UInt32) -> [String: String] {
        traces.lock.withLock { traces.values[windowID] ?? [:] }
    }
    private typealias MainConnection = @convention(c) () -> UInt32
    private typealias CopyManagedSpaces = @convention(c) (UInt32) -> Unmanaged<CFArray>?
    private typealias CopyWindowSpaces = @convention(c) (UInt32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias MoveWindows = @convention(c) (UInt32, CFArray, UInt64) -> Void
    private typealias ChangeMembership = @convention(c) (UInt32, CFArray, CFArray) -> Void

    // Immutable symbol bindings; the system image stays loaded for the process lifetime.
    private struct API: @unchecked Sendable {
        let connection: MainConnection
        let copyManaged: CopyManagedSpaces
        let copyWindows: CopyWindowSpaces
        let move: MoveWindows?
        let add: ChangeMembership?
        let remove: ChangeMembership?
    }

    private static let api: API? = {
        guard let image = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL) else {
            return nil
        }
        func symbol<T>(_ names: [String], as type: T.Type) -> T? {
            for name in names {
                if let address = dlsym(image, name) { return unsafeBitCast(address, to: type) }
            }
            return nil
        }
        guard let connection = symbol(["SLSMainConnectionID", "CGSMainConnectionID"], as: MainConnection.self),
              let copyManaged = symbol(["SLSCopyManagedDisplaySpaces", "CGSCopyManagedDisplaySpaces"], as: CopyManagedSpaces.self),
              let copyWindows = symbol(["SLSCopySpacesForWindows", "CGSCopySpacesForWindows"], as: CopyWindowSpaces.self) else {
            dlclose(image)
            return nil
        }
        return API(connection: connection, copyManaged: copyManaged, copyWindows: copyWindows,
                   move: symbol(["SLSMoveWindowsToManagedSpace", "CGSMoveWindowsToManagedSpace"], as: MoveWindows.self),
                   add: symbol(["SLSAddWindowsToSpaces", "CGSAddWindowsToSpaces"], as: ChangeMembership.self),
                   remove: symbol(["SLSRemoveWindowsFromSpaces", "CGSRemoveWindowsFromSpaces"], as: ChangeMembership.self))
    }()

    static func destinations() -> [SpaceDestination] {
        guard let api, let topology = api.copyManaged(api.connection())?.takeRetainedValue() else { return [] }
        let displays = topology as NSArray
        var result: [SpaceDestination] = []
        var seen: Set<UInt64> = []
        for case let display as NSDictionary in displays {
            guard let spaces = display["Spaces"] as? [NSDictionary] else { continue }
            for space in spaces {
                guard (space["type"] as? NSNumber)?.intValue == 0,
                      let number = (space["id64"] ?? space["ManagedSpaceID"]) as? NSNumber else { continue }
                let id = number.uint64Value
                guard id != 0, seen.insert(id).inserted else { continue }
                let ordinal = result.count + 1
                result.append(SpaceDestination(ordinal: ordinal, id: id, name: "桌面 \(ordinal)"))
            }
        }
        return result
    }

    static func badges(windowIDs: [UInt32]) -> [UInt32: Int] {
        guard !windowIDs.isEmpty, let api,
              let topology = api.copyManaged(api.connection())?.takeRetainedValue() else { return [:] }
        let visible = Set((topology as NSArray).compactMap { value -> UInt64? in
            guard let display = value as? NSDictionary, let current = display["Current Space"] as? NSDictionary else { return nil }
            return ((current["id64"] ?? current["ManagedSpaceID"]) as? NSNumber)?.uint64Value
        })
        let ordinals = Dictionary(destinations().map { ($0.id, $0.ordinal) }, uniquingKeysWith: { first, _ in first })
        var result: [UInt32: Int] = [:]
        for id in windowIDs {
            guard let membership = memberships(api: api, connection: api.connection(), windows: [NSNumber(value: id)] as CFArray),
                  membership.count == 1, let space = membership.first, !visible.contains(space), let ordinal = ordinals[space] else { continue }
            result[id] = ordinal
        }
        return result
    }

    static func moveToCurrent(windowID: UInt32) async -> Bool {
        guard let api, let topology = api.copyManaged(api.connection())?.takeRetainedValue() else { return false }
        // Prefer the display under the pointer, matching where the switcher is being used.
        let point = CGEvent(source: nil)?.location ?? .zero
        var displayID: CGDirectDisplayID = CGMainDisplayID()
        var count: UInt32 = 0
        _ = CGGetDisplaysWithPoint(point, 1, &displayID, &count)
        let displays = (topology as NSArray).compactMap { $0 as? NSDictionary }
        let displayUUID = uuidForDisplay(displayID)
        let matchingDisplay = displays.first { ($0["Display Identifier"] as? String) == displayUUID }
        let display: NSDictionary?
        if let matchingDisplay { display = matchingDisplay }
        else if displays.count == 1 { display = displays.first }
        else { return false }
        guard let current = display?["Current Space"] as? NSDictionary,
              let id = (current["id64"] ?? current["ManagedSpaceID"]) as? NSNumber,
              let destination = destinations().first(where: { $0.id == id.uint64Value }) else { return false }
        return await move(windowID: windowID, toOrdinal: destination.ordinal)
    }

    /// Returns true only after reading the target membership back from WindowServer.
    /// A symbol that exists but is rejected by newer macOS versions therefore reports failure.
    static func move(windowID: UInt32, toOrdinal ordinal: Int) async -> Bool {
        var trace: [String: String] = ["ordinal": "\(ordinal)"]
        defer {
            traces.lock.withLock {
                if traces.values.count > 32 { traces.values.removeAll() }
                traces.values[windowID] = trace
            }
        }
        guard windowID != 0, ordinal > 0, let api else { return false }
        let desktops = destinations()
        guard let target = desktops.first(where: { $0.ordinal == ordinal }) else { return false }
        let connection = api.connection()
        trace["connection"] = "\(connection)"; trace["target"] = "\(target.id)"
        let windows = [NSNumber(value: windowID)] as CFArray
        guard let previous = memberships(api: api, connection: connection, windows: windows),
              previous.count == 1, let oldSpace = previous.first,
              desktops.contains(where: { $0.id == oldSpace }) else {
            // Fullscreen and sticky/all-desktops windows are not ordinary movable windows.
            return false
        }
        if oldSpace == target.id { return true }
        trace["previous"] = previous.sorted().map(String.init).joined(separator: ",")
        if WSSubmitSpaceMove(windowID, target.id) {
            trace["bridgedSubmitted"] = "true"
            for _ in 0..<30 {
                if verify(api: api, connection: connection, windows: windows, target: target.id) {
                    trace["afterBridged"] = "\(target.id)"
                    return true
                }
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return false }
            }
            trace["afterBridged"] = memberships(api: api, connection: connection, windows: windows)?.sorted().map(String.init).joined(separator: ",") ?? "unavailable"
        }
        if let move = api.move {
            move(connection, windows, target.id)
            trace["afterMove"] = memberships(api: api, connection: connection, windows: windows)?.sorted().map(String.init).joined(separator: ",") ?? "unavailable"
            if verify(api: api, connection: connection, windows: windows, target: target.id) { return true }
        }
        guard let add = api.add, let remove = api.remove else { return false }
        add(connection, windows, [NSNumber(value: target.id)] as CFArray)
        trace["afterAdd"] = memberships(api: api, connection: connection, windows: windows)?.sorted().map(String.init).joined(separator: ",") ?? "unavailable"
        // Never remove the old membership unless the destination was actually added.
        guard let added = memberships(api: api, connection: connection, windows: windows),
              added.contains(target.id) else {
            let moved = moveToVisibleDisplay(windowID: windowID, targetSpace: target.id, api: api, trace: &trace)
            trace["visibleDisplayMove"] = "\(moved)"
            return moved
        }
        let ordinary = Set(desktops.map(\.id))
        let obsolete = added.intersection(ordinary).subtracting([target.id])
        if !obsolete.isEmpty {
            remove(connection, windows, obsolete.map { NSNumber(value: $0) } as CFArray)
        }
        trace["afterRemove"] = memberships(api: api, connection: connection, windows: windows)?.sorted().map(String.init).joined(separator: ",") ?? "unavailable"
        if verify(api: api, connection: connection, windows: windows, target: target.id) { return true }
        let moved = moveToVisibleDisplay(windowID: windowID, targetSpace: target.id, api: api, trace: &trace)
        trace["visibleDisplayMove"] = "\(moved)"
        return moved
    }

    /// Moving to another display's currently visible desktop has a public AX
    /// route. This does not change the user's active desktop or Dock settings.
    private static func moveToVisibleDisplay(windowID: UInt32, targetSpace: UInt64, api: API, trace: inout [String: String]) -> Bool {
        trace["fallbackStage"] = "permission-topology"
        guard AXIsProcessTrusted(), let topology = api.copyManaged(api.connection())?.takeRetainedValue() else { return false }
        let displays = (topology as NSArray).compactMap { $0 as? NSDictionary }
        trace["fallbackStage"] = "visible-target"
        guard let display = displays.first(where: {
            let current = $0["Current Space"] as? NSDictionary
            return ((current?["id64"] ?? current?["ManagedSpaceID"]) as? NSNumber)?.uint64Value == targetSpace
        }), let identifier = display["Display Identifier"] as? String else { return false }
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(32, &displayIDs, &count) == .success else { return false }
        trace["fallbackStage"] = "display-uuid"
        let targetDisplay = displayIDs.prefix(Int(count)).first { id in
            if identifier == "Main" { return id == CGMainDisplayID() }
            return uuidForDisplay(id)?.caseInsensitiveCompare(identifier) == .orderedSame
        }
        guard let targetDisplay else { return false }
        trace["fallbackStage"] = "window-identity"
        let rows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
        guard let row = rows.first(where: { $0[kCGWindowNumber as String] as? UInt32 == windowID }),
              let pid = row[kCGWindowOwnerPID as String] as? Int32,
              let rawFrame = row[kCGWindowBounds as String] as? NSDictionary,
              let oldFrame = CGRect(dictionaryRepresentation: rawFrame),
              let element = SingleWindowActivation.element(pid: pid, windowID: windowID) else { return false }
        AXUIElementSetMessagingTimeout(element, 0.12)
        trace["fallbackStage"] = "set-frame"
        let bounds = CGDisplayBounds(targetDisplay)
        let size = CGSize(width: min(oldFrame.width, max(100, bounds.width - 40)), height: min(oldFrame.height, max(100, bounds.height - 80)))
        var point = CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2)
        var newSize = size
        guard let position = AXValueCreate(.cgPoint, &point), let dimensions = AXValueCreate(.cgSize, &newSize) else { return false }
        trace["positionCode"] = "\(AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, position).rawValue)"
        trace["sizeCode"] = "\(AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, dimensions).rawValue)"
        trace["positionAgainCode"] = "\(AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, position).rawValue)"
        trace["fallbackStage"] = "readback"
        trace["afterAXSpaces"] = memberships(api: api, connection: api.connection(), windows: [NSNumber(value: windowID)] as CFArray)?.sorted().map(String.init).joined(separator: ",") ?? "unavailable"
        return verify(api: api, connection: api.connection(), windows: [NSNumber(value: windowID)] as CFArray, target: targetSpace)
    }

    private static func uuidForDisplay(_ id: CGDirectDisplayID) -> String? {
        typealias DisplayUUID = @convention(c) (UInt32) -> Unmanaged<CFUUID>?
        // On the current OS this CG-prefixed function is exported by SkyLight,
        // not CoreGraphics; a RTLD_LOCAL image is absent from dlsym(nil, ...).
        for path in ["/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics"] {
            guard let image = dlopen(path, RTLD_LAZY | RTLD_LOCAL) else { continue }
            defer { dlclose(image) }
            guard let address = dlsym(image, "CGDisplayCreateUUIDFromDisplayID") else { continue }
            let function = unsafeBitCast(address, to: DisplayUUID.self)
            if let uuid = function(id)?.takeRetainedValue() { return CFUUIDCreateString(nil, uuid) as String }
        }
        return nil
    }

    private static func memberships(api: API, connection: UInt32, windows: CFArray) -> Set<UInt64>? {
        guard let spaces = api.copyWindows(connection, 7, windows)?.takeRetainedValue() else { return nil }
        return Set((spaces as NSArray).compactMap { ($0 as? NSNumber)?.uint64Value })
    }

    private static func verify(api: API, connection: UInt32, windows: CFArray, target: UInt64) -> Bool {
        memberships(api: api, connection: connection, windows: windows) == [target]
    }
}
