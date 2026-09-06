import AppKit

/// The one place that watches display, Space and sleep events and reads the
/// window server's display and Space tables. The Space Switcher model, its
/// learning pass, display layout memory and switching all subscribe here and
/// read cached, generation-stamped tables instead of registering their own
/// observers and repeating the same queries. Nothing runs at idle: an event
/// only bumps a generation; a table is rebuilt lazily on the next read.
final class SpaceTopology: @unchecked Sendable {
    static let shared = SpaceTopology()

    enum Event: Equatable {
        /// CoreGraphics is about to reconfigure displays (already migrated
        /// Spaces on a real unplug, so this is not a "before" snapshot)
        case displaysWillChange
        /// CoreGraphics finished a reconfiguration step
        case displaysChanged
        case screenParametersChanged
        case activeSpaceChanged
        case willSleep
        case didWake
    }

    /// Online displays with stable identities. Rebuilt only after a display
    /// event, so the per-display UUID and IOKit reads happen once per
    /// reconfiguration instead of on every consumer call.
    struct DisplayTable {
        let generation: UInt64
        let probes: [DisplayIdentity.Probe]
        let identities: [CGDirectDisplayID: DisplayIdentity]
        /// Lowercased CGS "Display Identifier" (UUID, numeric id, or "main") → display
        let displayIDByIdentifier: [String: CGDirectDisplayID]
        let separateSpaces: Bool

        var signature: DisplayChangeCoalescer.Signature {
            DisplayChangeCoalescer.Signature(keys: Set(identities.values.map(\.key)), separateSpaces: separateSpaces)
        }

        var attachedKeys: Set<String> { Set(identities.values.map(\.key)) }

        func displayID(forCGSIdentifier identifier: String) -> CGDirectDisplayID? {
            displayIDByIdentifier[identifier.lowercased()]
        }

        func identity(forCGSIdentifier identifier: String) -> DisplayIdentity? {
            displayID(forCGSIdentifier: identifier).flatMap { identities[$0] }
        }

        func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
            NSScreen.screens.first { $0.displayID == displayID }
        }

        func screen(forCGSIdentifier identifier: String) -> NSScreen? {
            displayID(forCGSIdentifier: identifier).flatMap(screen(for:))
        }

        /// The display whose bounds contain a CG-global point
        func probe(containing point: CGPoint) -> DisplayIdentity.Probe? {
            probes.first { $0.bounds.contains(point) }
        }
    }

    /// CGSCopyManagedDisplaySpaces parsed once: canonical order (main display
    /// first, then left to right) with Mission Control desktop numbering.
    struct SpaceTable {
        let generation: UInt64
        let displayGeneration: UInt64
        let capturedAt: Date
        let displays: [DisplaySpaces]
        let knownSpaceIDs: Set<CGSSpaceID>
        let currentSpaceIDs: Set<CGSSpaceID>
        /// Each display's current Space with the display's CG frame, for
        /// attributing onscreen windows by position
        let currentSpaceByFrame: [(frame: CGRect, spaceID: CGSSpaceID)]

        func display(for identifier: String) -> DisplaySpaces? {
            displays.first { $0.identifier == identifier }
        }

        func currentSpaceID(containing point: CGPoint) -> CGSSpaceID? {
            currentSpaceByFrame.first { $0.frame.contains(point) }?.spaceID
        }
    }

    /// Window membership per Space from the window server — the expensive
    /// fan-out (one query per Space), cached until Spaces change or a move.
    struct MembershipTable {
        let generation: UInt64
        let spaceGeneration: UInt64
        let capturedAt: Date
        let spacesByWindow: [CGWindowID: Set<CGSSpaceID>]
        /// Window server order (frontmost first)
        let windowsBySpace: [CGSSpaceID: [CGWindowID]]
    }

    private let lock = NSLock()
    private var displayTable: DisplayTable?
    private var spaceTable: SpaceTable?
    private var membershipTable: MembershipTable?
    private var displayGeneration: UInt64 = 0
    private var spaceGeneration: UInt64 = 0
    private var membershipGeneration: UInt64 = 0
    private var subscribers: [UUID: (Event) -> Void] = [:]
    private var tokens: [NSObjectProtocol] = []

    private init() {
        let workspace = NSWorkspace.shared.notificationCenter
        tokens.append(workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.invalidateSpaces()
            self?.publish(.activeSpaceChanged)
        })
        tokens.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.invalidateDisplays()
            self?.publish(.screenParametersChanged)
        })
        tokens.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.publish(.willSleep)
        })
        tokens.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.invalidateDisplays()
            self?.publish(.didWake)
        })
        CGDisplayRegisterReconfigurationCallback(Self.reconfigurationCallback, Unmanaged.passUnretained(self).toOpaque())
    }

    private static let reconfigurationCallback: CGDisplayReconfigurationCallBack = { _, flags, userInfo in
        guard let userInfo else { return }
        let topology = Unmanaged<SpaceTopology>.fromOpaque(userInfo).takeUnretainedValue()
        let event: Event = flags.contains(.beginConfigurationFlag) ? .displaysWillChange : .displaysChanged
        let deliver = {
            if event == .displaysChanged { topology.invalidateDisplays() }
            topology.publish(event)
        }
        if Thread.isMainThread { deliver() } else { DispatchQueue.main.async(execute: deliver) }
    }

    // MARK: - Subscriptions (main thread)

    @discardableResult
    func subscribe(_ handler: @escaping (Event) -> Void) -> UUID {
        let id = UUID()
        subscribers[id] = handler
        return id
    }

    func unsubscribe(_ id: UUID) {
        subscribers[id] = nil
    }

    private func publish(_ event: Event) {
        for handler in subscribers.values {
            handler(event)
        }
    }

    // MARK: - Invalidation (O(1); all that runs at idle)

    func invalidateDisplays() {
        lock.withLock {
            displayGeneration += 1
            spaceGeneration += 1
            displayTable = nil
            spaceTable = nil
            membershipTable = nil
        }
    }

    func invalidateSpaces() {
        lock.withLock {
            spaceGeneration += 1
            spaceTable = nil
            membershipTable = nil
        }
    }

    /// After our own SLSMoveWindowsToManagedSpace the server's answer changed
    /// without any notification.
    func invalidateMembership() {
        lock.withLock {
            membershipGeneration += 1
            membershipTable = nil
        }
    }

    // MARK: - Reads (lazy)

    /// Never stale between display events, so no age limit.
    func displays() -> DisplayTable {
        if let table = lock.withLock({ displayTable }) { return table }
        let probes = DisplayIdentity.onlineProbes()
        let identities = DisplayIdentity.identities(for: probes)
        var byIdentifier: [String: CGDirectDisplayID] = [:]
        for probe in probes {
            byIdentifier[String(probe.displayID)] = probe.displayID
            if let uuid = probe.uuid { byIdentifier[uuid.lowercased()] = probe.displayID }
        }
        // "Main" is what CGS reports when displays do not have separate Spaces
        byIdentifier["main"] = CGMainDisplayID()
        let table = lock.withLock {
            DisplayTable(
                generation: displayGeneration,
                probes: probes,
                identities: identities,
                displayIDByIdentifier: byIdentifier,
                separateSpaces: NSScreen.screensHaveSeparateSpaces
            )
        }
        lock.withLock { displayTable = table }
        return table
    }

    /// `maxAge` 0 forces one CGSCopyManagedDisplaySpaces (cheap); the cached
    /// table is otherwise valid until a Space or display event — except for
    /// desktops created or removed in Mission Control, which macOS does not
    /// announce, so anything shown to the user should read fresh.
    func spaces(maxAge: TimeInterval = 0) -> SpaceTable {
        if maxAge > 0, let table = lock.withLock({ spaceTable }), Date().timeIntervalSince(table.capturedAt) <= maxAge {
            return table
        }
        let table = Self.parseManagedDisplaySpaces(displays: displays(), generation: lock.withLock { spaceGeneration })
        lock.withLock { spaceTable = table }
        return table
    }

    /// Window membership for every Space. Cached briefly: consecutive
    /// consumers (a learning pass, then a model build) share one fan-out.
    func membership(maxAge: TimeInterval = 1) -> MembershipTable {
        let space = spaces(maxAge: maxAge)
        if let table = lock.withLock({ membershipTable }),
           table.spaceGeneration == space.generation,
           Date().timeIntervalSince(table.capturedAt) <= maxAge
        {
            return table
        }
        let cid = CGSMainConnectionID()
        var spacesByWindow: [CGWindowID: Set<CGSSpaceID>] = [:]
        var windowsBySpace: [CGSSpaceID: [CGWindowID]] = [:]
        for display in space.displays {
            for info in display.spaces {
                let members = CGSCopyWindowsForSpace(cid, info.id)
                windowsBySpace[info.id] = members
                for wid in members {
                    spacesByWindow[wid, default: []].insert(info.id)
                }
            }
        }
        let table = MembershipTable(
            generation: lock.withLock { membershipGeneration },
            spaceGeneration: space.generation,
            capturedAt: Date(),
            spacesByWindow: spacesByWindow,
            windowsBySpace: windowsBySpace
        )
        lock.withLock { membershipTable = table }
        return table
    }

    // MARK: - Parsing

    private static func spaceID(from dictionary: [String: AnyObject]?) -> CGSSpaceID? {
        if let managedSpaceID = dictionary?["ManagedSpaceID"] as? NSNumber {
            return managedSpaceID.uint64Value
        }
        if let id64 = dictionary?["id64"] as? NSNumber {
            return id64.uint64Value
        }
        return nil
    }

    private static func parseManagedDisplaySpaces(displays table: DisplayTable, generation: UInt64) -> SpaceTable {
        let raw = CGSCopyManagedDisplaySpaces(CGSMainConnectionID()) as? [[String: AnyObject]] ?? []
        let mainScreen = NSScreen.screens.first

        let parsed: [(identifier: String, screen: NSScreen?, currentSpaceID: CGSSpaceID?, spaceDicts: [[String: AnyObject]])] = raw.compactMap { display in
            guard let identifier = display["Display Identifier"] as? String else { return nil }
            return (
                identifier: identifier,
                screen: table.screen(forCGSIdentifier: identifier),
                currentSpaceID: spaceID(from: display["Current Space"] as? [String: AnyObject]),
                spaceDicts: display["Spaces"] as? [[String: AnyObject]] ?? []
            )
        }

        // Main screen's display first, remaining left to right; unresolved displays last.
        let ordered = parsed.sorted { a, b in
            switch (a.screen, b.screen) {
            case let (sa?, sb?):
                let mainA = sa == mainScreen
                let mainB = sb == mainScreen
                if mainA != mainB { return mainA }
                return sa.frame.minX < sb.frame.minX
            case (nil, nil): return a.identifier < b.identifier
            case (nil, _): return false
            case (_, nil): return true
            }
        }

        // Desktop numbering is global and continuous across displays, matching
        // Mission Control (fullscreen-app spaces are unnumbered).
        var desktopCounter = 0
        var knownSpaceIDs: Set<CGSSpaceID> = []
        var currentSpaceIDs: Set<CGSSpaceID> = []
        var currentSpaceByFrame: [(frame: CGRect, spaceID: CGSSpaceID)] = []
        let displays = ordered.map { display in
            let spaces: [SpaceInfo] = display.spaceDicts.compactMap { dict in
                guard let id = spaceID(from: dict) else { return nil }
                let type = (dict["type"] as? NSNumber)?.intValue ?? 0
                if type != 4 { desktopCounter += 1 }
                knownSpaceIDs.insert(id)
                return SpaceInfo(
                    id: id,
                    uuid: dict["uuid"] as? String ?? "",
                    type: type,
                    displayIdentifier: display.identifier,
                    desktopNumber: type == 4 ? 0 : desktopCounter,
                    isCurrent: id == display.currentSpaceID
                )
            }
            if let current = display.currentSpaceID {
                currentSpaceIDs.insert(current)
                if let screen = display.screen {
                    currentSpaceByFrame.append((screen.cgFrame, current))
                }
            }
            return DisplaySpaces(identifier: display.identifier, screen: display.screen, currentSpaceID: display.currentSpaceID, spaces: spaces)
        }

        return SpaceTable(
            generation: generation,
            displayGeneration: table.generation,
            capturedAt: Date(),
            displays: displays,
            knownSpaceIDs: knownSpaceIDs,
            currentSpaceIDs: currentSpaceIDs,
            currentSpaceByFrame: currentSpaceByFrame
        )
    }
}
