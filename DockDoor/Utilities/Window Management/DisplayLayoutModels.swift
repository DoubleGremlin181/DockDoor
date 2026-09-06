import AppKit
import Defaults

// MARK: - Persisted records

/// One desktop of a display as the Space Switcher last saw it. `id` is the
/// runtime space ID (macOS keeps it for desktops it moves intact to another
/// display); `uuid` is the persistent desktop identity.
struct SpaceRecord: Codable, Hashable {
    let uuid: String
    let id: CGSSpaceID
    /// Position in Mission Control order on its display
    let index: Int
    let isFullscreen: Bool
    let wasCurrent: Bool
}

struct DisplaySpacesRecord: Codable, Hashable {
    let identity: DisplayIdentity
    let spaces: [SpaceRecord]
    let updatedAt: Date

    /// Same desktops in the same order (timestamps and the current-desktop
    /// marker ignored, so plain space switches never rewrite the store)
    func isEquivalent(to other: DisplaySpacesRecord) -> Bool {
        identity == other.identity && spaces.count == other.spaces.count
            && zip(spaces, other.spaces).allSatisfy { a, b in
                a.uuid == b.uuid && a.id == b.id && a.index == b.index && a.isFullscreen == b.isFullscreen
            }
    }
}

/// A display that is currently absent, with everything needed to put its
/// windows back when it returns.
struct PendingRestore: Codable, Hashable {
    let displayKey: String
    let record: DisplaySpacesRecord
    let removedAt: Date
    /// Window IDs only mean something within the login session that minted them
    let sessionToken: String
    /// Display whose desktops absorbed the removed display's windows
    let hostDisplayKey: String
    /// Remembered desktop uuid → window IDs the Space Switcher had learned on it
    let windowsBySpace: [String: [CGWindowID]]
    /// Remembered desktop uuid → uuid of the desktop it lives on while absent
    var migrations: [String: String]
    /// Desktops of the other displays before the removal — a window found on
    /// one of these was put there on purpose
    let preexistingSpaceUUIDs: Set<String>
    /// Window → frame relative to the removed display's bounds, as last seen
    /// there by the Space Switcher (CG coordinates, points)
    var frames: [CGWindowID: CGRect] = [:]
    /// Remembered desktop uuid → target desktop uuid chosen at the first restore pass
    var assignments: [String: String] = [:]
    var restoredAt: Date?
}

struct DisplayLayoutStore: Codable {
    static let maxDisplays = 16

    var version = 2
    var displays: [String: DisplaySpacesRecord] = [:]
    var pending: [String: PendingRestore] = [:]

    /// Records a display's desktops; returns whether anything changed.
    @discardableResult
    mutating func note(_ record: DisplaySpacesRecord) -> Bool {
        if let existing = displays[record.identity.key], existing.isEquivalent(to: record) {
            return false
        }
        displays[record.identity.key] = record
        prune()
        return true
    }

    mutating func prune() {
        let excess = displays.count - Self.maxDisplays
        guard excess > 0 else { return }
        let victims = displays.values
            .filter { pending[$0.identity.key] == nil }
            .sorted { $0.updatedAt < $1.updatedAt }
            .prefix(excess)
        for victim in victims {
            displays.removeValue(forKey: victim.identity.key)
        }
    }
}

extension DisplayLayoutStore {
    private static let storeKey = Defaults.Key<Data>("spaceSwitcherDisplayLayoutStore", default: Data())

    static func load() -> DisplayLayoutStore {
        let data = Defaults[storeKey]
        guard !data.isEmpty,
              let store = try? JSONDecoder().decode(DisplayLayoutStore.self, from: data),
              store.version == DisplayLayoutStore().version
        else { return DisplayLayoutStore() }
        return store
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            Defaults[Self.storeKey] = data
        }
    }

    static func clear() {
        Defaults[storeKey] = Data()
    }

    /// Window and space IDs are minted by the window server, which restarts
    /// on logout; loginwindow's launch time identifies the session.
    static func currentSessionToken() -> String {
        if let loginwindow = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.loginwindow").first,
           let launched = loginwindow.launchDate
        {
            return "login:\(Int(launched.timeIntervalSince1970))"
        }
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        if sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 {
            return "boot:\(boot.tv_sec)-\(NSUserName())"
        }
        return "unknown"
    }
}

// MARK: - Live state (never persisted)

struct LiveDisplay: Hashable {
    let identity: DisplayIdentity
    let displayID: CGDirectDisplayID
    /// CG global coordinates
    let bounds: CGRect
    /// CG global coordinates, minus menu bar and Dock
    let visibleBounds: CGRect
    let isMain: Bool
}

struct LiveSpace: Hashable {
    let id: CGSSpaceID
    let uuid: String
    let displayKey: String
    let isFullscreen: Bool
    let isCurrent: Bool
    /// Windows attributed to this space, z-order (frontmost first)
    let windowIDs: [CGWindowID]
}

struct LiveWindow: Hashable {
    let id: CGWindowID
    let pid: pid_t
    /// CG global coordinates
    let frame: CGRect
    /// Attributed to several spaces — never moved
    let isSticky: Bool
}

struct LiveState {
    let displays: [String: LiveDisplay]
    let spaces: [LiveSpace]
    let windows: [CGWindowID: LiveWindow]

    func spaces(on displayKey: String) -> [LiveSpace] {
        spaces.filter { $0.displayKey == displayKey }
    }

    func space(containing windowID: CGWindowID) -> LiveSpace? {
        spaces.first { $0.windowIDs.contains(windowID) }
    }

    func space(uuid: String) -> LiveSpace? {
        spaces.first { $0.uuid == uuid }
    }

    var mainDisplayKey: String? {
        displays.values.first { $0.isMain }?.identity.key
    }

    func record(for displayKey: String, at date: Date = Date()) -> DisplaySpacesRecord? {
        guard let display = displays[displayKey] else { return nil }
        let spaces = spaces(on: displayKey).enumerated().map { index, space in
            SpaceRecord(uuid: space.uuid, id: space.id, index: index, isFullscreen: space.isFullscreen, wasCurrent: space.isCurrent)
        }
        return DisplaySpacesRecord(identity: display.identity, spaces: spaces, updatedAt: date)
    }
}

extension LiveState {
    /// The Space Switcher's own model (fresh CGS membership, frames, sticky
    /// attribution) reshaped for the reconciler.
    @MainActor
    static func capture() -> LiveState {
        let model = SpaceSwitcherEngine.buildModel()
        let identities = DisplayIdentity.identities(for: DisplayIdentity.onlineProbes())
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0

        var displays: [String: LiveDisplay] = [:]
        var keyByIdentifier: [String: String] = [:]
        for display in model.displays {
            guard let screen = display.screen,
                  let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let identity = identities[number.uint32Value]
            else { continue }
            let visible = screen.visibleFrame
            displays[identity.key] = LiveDisplay(
                identity: identity,
                displayID: number.uint32Value,
                bounds: CGDisplayBounds(number.uint32Value),
                visibleBounds: CGRect(x: visible.minX, y: primaryHeight - visible.maxY, width: visible.width, height: visible.height),
                isMain: screen == NSScreen.screens.first
            )
            keyByIdentifier[display.identifier] = identity.key
        }

        var windows: [CGWindowID: LiveWindow] = [:]
        var spaces: [LiveSpace] = []
        for display in model.displays {
            guard let key = keyByIdentifier[display.identifier] else { continue }
            for space in display.spaces {
                let bucket = model.windowsBySpace[space.id] ?? []
                for window in bucket {
                    let sticky = window.isSticky || windows[window.id] != nil
                    windows[window.id] = LiveWindow(id: window.id, pid: window.pid, frame: window.frame, isSticky: sticky)
                }
                spaces.append(LiveSpace(
                    id: space.id,
                    uuid: space.uuid,
                    displayKey: key,
                    isFullscreen: space.isFullscreen,
                    isCurrent: space.isCurrent,
                    windowIDs: bucket.map(\.id)
                ))
            }
        }
        return LiveState(displays: displays, spaces: spaces, windows: windows)
    }
}
